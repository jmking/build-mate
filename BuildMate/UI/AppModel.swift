import AppKit
import GRDB
import Observation

struct AppSnapshot: Sendable {
    var projects: [Project] = []
    var tasks: [WorkTask] = []
    var sessions: [Session] = []
    var messages: [Message] = []
    var questions: [Question] = []
    var approvals: [Approval] = []
    var proofs: [Proof] = []
}

enum Destination: Hashable {
    case needsYou
    case project(UUID, ProjectPage)
    case task(UUID)
}
enum ProjectPage: String, CaseIterable, Identifiable {
    case chat = "Chat", backlog = "Backlog", tasks = "Tasks", instructions = "Instructions"
    var id: Self { self }
    var symbol: String {
        switch self { case .chat: "bubble.left"; case .backlog: "list.bullet.rectangle"; case .tasks: "rectangle.split.3x1"; case .instructions: "doc.text" }
    }
}

@MainActor @Observable
final class AppModel {
    let store: Store
    let core: Orchestrator
    var snapshot = AppSnapshot()
    var settings = AppSettings()
    var destination: Destination? = .needsYou {
        didSet {
            guard destination != oldValue else { return }
            if !traversingHistory, let oldValue { backHistory.append(oldValue); forwardHistory.removeAll() }
            if case .project(let id, _) = destination { lastProjectID = id }
            if case .task(let id) = destination { lastProjectID = snapshot.tasks.first { $0.id == id }?.projectId ?? lastProjectID }
            saveSelection()
        }
    }
    private var lastProjectID: UUID?
    private var backHistory: [Destination] = []
    private var forwardHistory: [Destination] = []
    private var traversingHistory = false
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var findRequested = false
    var showAddProject = false
    var showNewTask = false
    var editingTask: WorkTask?
    var showInspector = true
    var listMode = false
    var search = ""
    var error: String?
    var schedulerError: String?
    private var observing = false

    init(store: Store, runner: ProcessRunner = ProcessRunner()) { self.store = store; core = Orchestrator(store: store, runner: runner) }

    func observe() async {
        guard !observing else { return }
        observing = true
        await refresh()
        restoreSelection()
        showAddProject = snapshot.projects.isEmpty
        await core.start()
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
        observing = false
    }
    func refresh() async {
        do {
            snapshot = try await store.db.read { db in
                AppSnapshot(projects: try Project.order(Column("name")).fetchAll(db),
                            tasks: try WorkTask.order(Column("rank").desc, Column("createdAt")).fetchAll(db),
                            sessions: try Session.fetchAll(db), messages: try Message.order(Column("createdAt")).fetchAll(db),
                            questions: try Question.fetchAll(db), approvals: try Approval.fetchAll(db), proofs: try Proof.fetchAll(db))
            }
            settings = try store.settings()
            schedulerError = await core.lastError
        } catch { self.error = error.localizedDescription }
    }
    var selectedProject: Project? {
        switch destination {
        case .project(let id, _): snapshot.projects.first { $0.id == id }
        case .task(let id): snapshot.tasks.first { $0.id == id }.flatMap { task in snapshot.projects.first { $0.id == task.projectId } }
        default: snapshot.projects.first { $0.id == lastProjectID }
        }
    }
    var selectedTask: WorkTask? {
        guard case .task(let id) = destination else { return nil }
        return snapshot.tasks.first { $0.id == id }
    }
    func retryNeedsAttention(_ task: WorkTask) -> Bool {
        guard task.retry != nil, !task.state.terminal else { return false }
        return !snapshot.sessions.contains { $0.ownerId == task.id && $0.status == "running" && $0.currentTurn != nil }
            && !snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil }
            && !snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" }
    }
    func needsYou(_ task: WorkTask) -> Bool {
        !task.state.terminal && (task.state == .humanReview || snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil }
            || snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" } || retryNeedsAttention(task))
    }
    var needsCount: Int { snapshot.tasks.filter(needsYou).count }
    var workers: Int { snapshot.sessions.filter { $0.status == "running" }.count }
    func projectName(_ id: UUID) -> String { snapshot.projects.first { $0.id == id }?.name ?? "Project" }
    func tasks(_ id: UUID) -> [WorkTask] {
        snapshot.tasks.filter { $0.projectId == id && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || String($0.number).contains(search)) }
    }
    func navigate(_ page: ProjectPage) {
        if let project = selectedProject ?? snapshot.projects.first { destination = .project(project.id, page) }
    }
    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        if let destination { forwardHistory.append(destination) }
        traversingHistory = true; destination = previous; traversingHistory = false
    }
    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        if let destination { backHistory.append(destination) }
        traversingHistory = true; destination = next; traversingHistory = false
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation(); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func add(_ discovered: DiscoveredProject) throws {
        guard !snapshot.projects.contains(where: { $0.repoPath == discovered.project.repoPath }) else { throw CoreError.invalid("This clone is already a project.") }
        try store.save(discovered.project)
        try store.workflow(for: discovered.project)
        destination = .project(discovered.project.id, .tasks)
        showAddProject = false
    }
    func createProject(path: String) async throws {
        let discovered = try await ProjectDiscovery(runner: core.runner).create(path: path)
        try add(discovered)
        await refresh()
    }
    func createTask(projectID: UUID, title: String, description: String, start: Bool, proofRequirement: ProofRequirement = .automatic) async throws {
        let project = try store.get(Project.self, projectID)
        if start, let reason = project.runBlockReason { throw CoreError.invalid(reason) }
        var resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTitle.isEmpty || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalid("Describe what you would like built.")
        }
        if resolvedTitle.isEmpty { resolvedTitle = await core.generateTitle(for: description, model: project.settings.model) }
        try Task.checkCancellation()
        // Configuration may have changed while the title was being generated.
        if start, let reason = try store.get(Project.self, projectID).runBlockReason { throw CoreError.invalid(reason) }
        let task = try store.createTask(projectId: projectID, title: resolvedTitle, description: description, state: start ? .todo : .backlog, proofRequirement: proofRequirement)
        showNewTask = false; destination = .task(task.id)
        await core.tick()
    }
    func editTask(_ id: UUID, title: String, description: String, proofRequirement: ProofRequirement) async throws {
        try await core.editTask(id, title: title, description: description, proofRequirement: proofRequirement)
        await refresh()
    }
    func moveToTodo(_ task: WorkTask) async throws {
        let project = try store.get(Project.self, task.projectId)
        if let reason = project.runBlockReason { throw CoreError.invalid(reason) }
        try await core.transition(task.id, to: .todo)
        await core.tick()
    }
    func pauseAll() throws { var value = try store.settings(); value.paused.toggle(); try store.saveSettings(value); Task { await core.tick() } }
    func pauseProject(_ project: Project) throws {
        guard project.host != .bitbucket else { throw CoreError.invalid("Bitbucket task runs remain paused until its integration is verified.") }
        var current = try store.get(Project.self, project.id); current.paused.toggle(); try store.save(current); Task { await core.tick() }
    }
    private var selectionURL: URL { store.root.appending(path: "selection.json") }
    private func saveSelection() {
        var value: [String: String] = [:]
        switch destination {
        case .needsYou: value["page"] = "needsYou"
        case .project(let id, let page): value = ["project": id.uuidString, "page": page.rawValue]
        case .task(let id): value = ["task": id.uuidString]
        default: return
        }
        value["lastProject"] = lastProjectID?.uuidString
        do { try JSONEncoder().encode(value).write(to: selectionURL, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    private func restoreSelection() {
        guard let data = try? Data(contentsOf: selectionURL), let value = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        lastProjectID = value["lastProject"].flatMap(UUID.init(uuidString:))
        if let id = value["task"].flatMap(UUID.init(uuidString:)), snapshot.tasks.contains(where: { $0.id == id }) { destination = .task(id) }
        else if let id = value["project"].flatMap(UUID.init(uuidString:)), snapshot.projects.contains(where: { $0.id == id }), let page = value["page"].flatMap(ProjectPage.init(rawValue:)) { destination = .project(id, page) }
    }
}
