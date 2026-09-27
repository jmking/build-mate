import AppKit
import GRDB
import Observation

struct AttentionItem: Identifiable, Sendable {
    var id: String
    var ownerID: UUID
    var ownerType = "task"
    var projectID: UUID
    var title: String
    var detail: String
}

struct AppSnapshot: Sendable {
    var agentConfigurations: [AgentConfiguration] = []
    var projects: [Project] = []
    var repositories: [ProjectRepository] = []
    var tasks: [WorkTask] = []
    var sessions: [Session] = []
    var subagents: [Subagent] = []
    var messages: [Message] = []
    var questions: [Question] = []
    var approvals: [Approval] = []
    var proofs: [Proof] = []
    var proposals: [Proposal] = []
    var attachments: [Attachment] = []
}

enum Destination: Hashable {
    case needsYou
    case project(UUID, ProjectPage)
    case task(UUID)
}
enum ProjectPage: String, CaseIterable, Identifiable {
    case chat = "Chat", tasks = "Tasks", instructions = "Instructions"
    var id: Self { self }
    var symbol: String {
        switch self { case .chat: "bubble.left"; case .tasks: "rectangle.split.3x1"; case .instructions: "doc.text" }
    }
}

@MainActor @Observable
final class AppModel {
    var settingsTab = "general"
    var settingsProjectID: UUID?
    var onRefresh: (([AttentionItem]) -> Void)?
    let store: Store
    let core: Orchestrator
    var snapshot = AppSnapshot()
    var settings = AppSettings()
    var destination: Destination? = .needsYou {
        didSet {
            guard destination != oldValue else { return }
            priorityDrag = nil
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
    var taskToDelete: WorkTask?
    var deletingTasks: Set<UUID> = []
    private struct ViewPreferences: Codable {
        var inspector = false
        var listMode = false
        var projects: [String: Bool] = [:]
        var briefs: [String: Bool] = [:]
    }
    private var viewPreferences = ViewPreferences() {
        didSet { try? JSONEncoder().encode(viewPreferences).write(to: store.root.appending(path: "view-preferences.json"), options: .atomic) }
    }
    var showInspector: Bool {
        get { viewPreferences.inspector }
        set { viewPreferences.inspector = newValue }
    }
    var toggleSidebar = false
    var listMode: Bool {
        get { viewPreferences.listMode }
        set { viewPreferences.listMode = newValue }
    }
    private var searches: [Destination: String] = [:]
    var canSearch: Bool {
        switch destination { case .needsYou, nil, .project(_, .tasks): true; default: false }
    }
    var search: String {
        get { canSearch ? searches[destination ?? .needsYou, default: ""] : "" }
        set { if canSearch { searches[destination ?? .needsYou] = newValue } }
    }
    var chatDrafts: [UUID: String] = [:]
    var attachmentDrafts: [UUID: [URL]] = [:]
    var error: String?
    private var backgroundIssues: [BackgroundIssue] = []
    private var visibleIssue: BackgroundIssue? {
        let projectID: UUID?
        switch destination {
        case .project(let id, _): projectID = id
        case .task: projectID = selectedTask?.projectId
        default: projectID = nil
        }
        return backgroundIssues.first { issue in
            if let taskID = issue.taskID { return selectedTask?.id == taskID || (selectedTask == nil && projectID != nil && projectID == snapshot.tasks.first { $0.id == taskID }?.projectId) }
            if let owner = issue.projectID { return projectID == owner }
            return true
        }
    }
    var schedulerError: String? {
        guard let issue = visibleIssue else { return nil }
        if let task = snapshot.tasks.first(where: { $0.id == issue.taskID }), selectedTask == nil {
            return "\(task.title): \(issue.message)"
        }
        return issue.message
    }
    var usage = UsageSnapshot()
    var usageHeld = false
    var previews: [UUID: PreviewStatus] = [:]
    var reviewSheet: ReviewSheet?
    var priorityDrag: PriorityDrag?
    private var observing = false

    struct PriorityDrag {
        let taskID: UUID
        let projectID: UUID
        let state: TaskState
        var targetID: UUID?
        var after = false
    }

    init(store: Store, runner: ProcessRunner = ProcessRunner()) {
        self.store = store; core = Orchestrator(store: store, runner: runner)
        if let data = try? Data(contentsOf: store.root.appending(path: "view-preferences.json")),
           let value = try? JSONDecoder().decode(ViewPreferences.self, from: data) { viewPreferences = value }
    }

    func isProjectExpanded(_ id: UUID) -> Bool { viewPreferences.projects[id.uuidString] ?? (selectedProject?.id == id) }
    func setProjectExpanded(_ id: UUID, expanded: Bool) { viewPreferences.projects[id.uuidString] = expanded }
    func isBriefExpanded(_ task: WorkTask) -> Bool { viewPreferences.briefs[task.id.uuidString] ?? (task.state == .todo && task.worktreePath == nil) }
    func setBriefExpanded(_ id: UUID, expanded: Bool) { viewPreferences.briefs[id.uuidString] = expanded }
    func dismissSchedulerError() {
        guard let issue = visibleIssue else { return }
        backgroundIssues.removeAll { $0.id == issue.id }
        Task { await core.dismissBackgroundIssue(issue.id) }
    }

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
                AppSnapshot(agentConfigurations: try AgentConfiguration.fetchAll(db), projects: try Project.order(Column("name")).fetchAll(db), repositories: try ProjectRepository.fetchAll(db),
                            tasks: try WorkTask.order(Column("rank").desc, Column("createdAt")).fetchAll(db),
                            sessions: try Session.fetchAll(db), subagents: try Subagent.fetchAll(db), messages: try Message.order(Column("createdAt")).fetchAll(db),
                            questions: try Question.fetchAll(db), approvals: try Approval.fetchAll(db), proofs: try Proof.fetchAll(db), proposals: try Proposal.fetchAll(db), attachments: try Attachment.fetchAll(db))
            }
            settings = try store.settings()
            backgroundIssues = await core.backgroundIssues.values.sorted { $0.id < $1.id }
            usage = await core.usage
            usageHeld = await core.usageHeld()
            previews = await core.previews
            onRefresh?(attentionItems)
        } catch { self.error = error.localizedDescription }
    }
    var attentionItems: [AttentionItem] {
        var result: [AttentionItem] = []
        for task in snapshot.tasks where !task.state.terminal {
            for question in snapshot.questions where question.taskId == task.id && question.answer == nil {
                result.append(AttentionItem(id: "question-\(question.id)", ownerID: task.id, projectID: task.projectId, title: task.title, detail: "Answer a question"))
            }
            for approval in snapshot.approvals where approval.taskId == task.id && approval.status == "pending" {
                result.append(AttentionItem(id: "approval-\(approval.id)", ownerID: task.id, projectID: task.projectId, title: task.title, detail: "Approval needed"))
            }
            if task.state == .humanReview {
                let proof = snapshot.proofs.first { $0.taskId == task.id }
                result.append(AttentionItem(id: "review-\(proof?.id ?? task.id)-\(proof?.producedAt.timeIntervalSince1970 ?? 0)", ownerID: task.id, projectID: task.projectId, title: task.title, detail: "Awaiting human review"))
            }
            if retryNeedsAttention(task) {
                result.append(AttentionItem(id: "retry-\(task.id)-\(task.retry?.dueAt.timeIntervalSince1970 ?? 0)", ownerID: task.id, projectID: task.projectId, title: task.title, detail: "Agent needs help"))
            }
        }
        for project in snapshot.projects {
            for message in projectQuestions where snapshot.sessions.contains(where: { $0.id == message.sessionId && $0.ownerType == "project" && $0.ownerId == project.id }) {
                result.append(AttentionItem(id: "project-question-\(message.id)", ownerID: project.id, ownerType: "project", projectID: project.id, title: project.name, detail: "Project chat has a question"))
            }
        }
        return result
    }
    func repositories(_ projectID: UUID) -> [ProjectRepository] {
        snapshot.repositories.filter { $0.projectId == projectID && !$0.removed }
            .sorted { if ($0.id == projectID) != ($1.id == projectID) { return $0.id == projectID }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func project(for task: WorkTask) -> Project? {
        guard let project = snapshot.projects.first(where: { $0.id == task.projectId }),
              let repository = snapshot.repositories.first(where: { $0.id == (task.repositoryID ?? task.projectId) }) else { return nil }
        return repository.applying(to: project)
    }
    func repositoryName(for task: WorkTask) -> String {
        snapshot.repositories.first { $0.id == (task.repositoryID ?? task.projectId) }?.name ?? "Repository"
    }
    private func projectForNavigation(_ id: UUID?) -> Project? {
        guard let project = snapshot.projects.first(where: { $0.id == id }) else { return nil }
        return repositories(project.id).first?.applying(to: project) ?? project
    }
    var selectedProject: Project? {
        switch destination {
        case .project(let id, _): projectForNavigation(id)
        case .task(let id): snapshot.tasks.first { $0.id == id }.flatMap { project(for: $0) }
        default: projectForNavigation(lastProjectID)
        }
    }
    var selectedTask: WorkTask? {
        guard case .task(let id) = destination else { return nil }
        return snapshot.tasks.first { $0.id == id }
    }
    func retryNeedsAttention(_ task: WorkTask) -> Bool {
        guard let retry = task.retry, retry.attempt == 0 || retry.attempt >= 3, task.paused, !task.state.terminal else { return false }
        return !snapshot.sessions.contains { $0.ownerId == task.id && $0.status == "running" && $0.currentTurn != nil }
            && !snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil }
            && !snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" }
    }
    func needsYou(_ task: WorkTask) -> Bool {
        !task.state.terminal && (task.state == .humanReview || snapshot.questions.contains { $0.taskId == task.id && $0.answer == nil }
            || snapshot.approvals.contains { $0.taskId == task.id && $0.status == "pending" } || retryNeedsAttention(task))
    }
    var projectQuestions: [Message] {
        let sessions = Set(snapshot.sessions.filter { $0.ownerType == "project" }.map(\.id))
        return snapshot.messages.filter { sessions.contains($0.sessionId) && $0.kind == "question" && $0.payload["answer"] == .null }
    }
    func chatQuestionCount(_ projectID: UUID) -> Int {
        let sessionID = snapshot.sessions.first { $0.ownerType == "project" && $0.ownerId == projectID }?.id
        return projectQuestions.filter { $0.sessionId == sessionID }.count
    }
    var needsCount: Int { snapshot.tasks.filter(needsYou).count + projectQuestions.count }
    var workers: Int { snapshot.sessions.filter { ["running", "waiting"].contains($0.status) }.count }
    func projectName(_ id: UUID) -> String { snapshot.projects.first { $0.id == id }?.name ?? "Project" }
    func projectChatWaitingReason(_ projectID: UUID) -> String? {
        guard let project = snapshot.projects.first(where: { $0.id == projectID }),
              let session = snapshot.sessions.first(where: { $0.ownerType == "project" && $0.ownerId == projectID }),
              ["queued", "running", "waiting"].contains(session.status) else { return nil }
        if settings.paused { return "All work is paused" }
        if project.paused { return "Project is paused" }
        if session.status == "waiting" { return "Waiting for your answer" }
        if session.status == "running" { return nil }
        if usageHeld { return "Waiting for usage to reset" }
        if usage.refreshing && usage.updatedAt == nil { return "Checking account usage…" }
        return "Waiting for an agent"
    }
    func waitingReason(for task: WorkTask) -> String? {
        guard !task.state.terminal else { return nil }
        if task.paused { return retryNeedsAttention(task) ? "Review the issue before resuming" : "Paused" }
        if settings.paused { return "All work is paused" }
        if let project = project(for: task) {
            if project.paused { return "Project is paused" }
            if let reason = project.runBlockReason { return reason }
        }
        if snapshot.sessions.contains(where: { $0.ownerId == task.id && $0.status == "running" && $0.currentTurn != nil }) { return nil }
        for id in Set(task.dependsOn + (task.stackOn.map { [$0] } ?? [])) {
            guard let dependency = snapshot.tasks.first(where: { $0.id == id && $0.projectId == task.projectId }) else { return "A dependency is unavailable" }
            if dependency.state != .done && !(task.stackOn == id && dependency.state == .inPR && dependency.pr != nil) { return "Waiting for \(dependency.title)" }
        }
        if task.retry != nil { return "Retrying automatically…" }
        guard [.todo, .building].contains(task.state) else { return nil }
        if snapshot.approvals.contains(where: { $0.taskId == task.id && $0.status == "pending" }) { return snapshot.approvals.contains(where: { $0.taskId == task.id && $0.kind == "merge" && $0.status == "pending" }) ? "Waiting for merge approval" : "Waiting for plan approval" }
        if usageHeld { return "Waiting for usage to reset" }
        if usage.refreshing && usage.updatedAt == nil { return "Checking account usage…" }
        return "Waiting for an agent"
    }
    func hasSuggestedAnswers(for taskID: UUID) -> Bool {
        let pending = snapshot.questions.filter { $0.taskId == taskID && $0.answer == nil && $0.blocking }
        return !pending.isEmpty && pending.allSatisfy { $0.suggestedAnswer != nil }
    }
    func tasks(_ id: UUID) -> [WorkTask] {
        var tasks = snapshot.tasks.filter { $0.projectId == id }
        if let drag = priorityDrag, drag.projectID == id,
           let source = tasks.firstIndex(where: { $0.id == drag.taskID && $0.state == drag.state }),
           let targetID = drag.targetID, tasks.contains(where: { $0.id == targetID && $0.state == drag.state }) {
            let task = tasks.remove(at: source)
            if let target = tasks.firstIndex(where: { $0.id == targetID }) {
                tasks.insert(task, at: target + (drag.after ? 1 : 0))
            }
        }
        let query = searches[.project(id, .tasks), default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }
    func beginPriorityDrag(_ task: WorkTask) {
        guard task.state == .todo else { return }
        priorityDrag = PriorityDrag(taskID: task.id, projectID: task.projectId, state: task.state)
    }
    func canDropPriority(on task: WorkTask) -> Bool {
        guard let drag = priorityDrag else { return false }
        return task.projectId == drag.projectID && task.state == drag.state
            && snapshot.tasks.contains { $0.id == drag.taskID && $0.projectId == drag.projectID && $0.state == drag.state }
    }
    func previewPriorityDrag(over task: WorkTask, after: Bool) {
        guard canDropPriority(on: task), priorityDrag?.taskID != task.id else { return }
        priorityDrag?.targetID = task.id
        priorityDrag?.after = after
    }
    func finishPriorityDrag(commit: Bool) {
        defer { priorityDrag = nil }
        guard commit, let drag = priorityDrag, let targetID = drag.targetID else { return }
        do { try reorderTask(drag.taskID, relativeTo: targetID, after: drag.after) }
        catch { self.error = error.localizedDescription }
    }
    func navigate(_ page: ProjectPage) {
        if let project = selectedProject ?? snapshot.projects.first { destination = .project(project.id, page) }
    }
    func reorderTask(_ id: UUID, relativeTo targetID: UUID, after: Bool) throws {
        guard id != targetID else { return }
        try store.db.write { db in
            guard let task = try WorkTask.fetchOne(db, key: id), let target = try WorkTask.fetchOne(db, key: targetID),
                  task.projectId == target.projectId, task.state == target.state, task.state == .todo else {
                throw CoreError.invalid("Reorder tasks within the same project's Queue list.")
            }
            var group = try WorkTask.filter(Column("projectId") == task.projectId && Column("state") == task.state.rawValue)
                .order(Column("rank").desc, Column("createdAt")).fetchAll(db).map(\.id)
            group.removeAll { $0 == id }
            guard let index = group.firstIndex(of: targetID) else { return }
            group.insert(id, at: index + (after ? 1 : 0))
            for (index, taskID) in group.enumerated() {
                try db.execute(sql: "UPDATE task SET rank = ?, updatedAt = ? WHERE id = ?", arguments: [group.count - index, Date(), taskID])
            }
        }
        // Publish the saved order immediately so dropping never flashes the old order.
        snapshot.tasks = try store.db.read { try WorkTask.order(Column("rank").desc, Column("createdAt")).fetchAll($0) }
    }
    func priorityNeighbor(_ task: WorkTask, earlier: Bool) -> WorkTask? {
        guard task.state == .todo else { return nil }
        let group = snapshot.tasks.filter { $0.projectId == task.projectId && $0.state == task.state }
        guard let index = group.firstIndex(where: { $0.id == task.id }) else { return nil }
        let next = index + (earlier ? -1 : 1)
        return group.indices.contains(next) ? group[next] : nil
    }
    func movePriority(_ task: WorkTask, earlier: Bool) throws {
        if let target = priorityNeighbor(task, earlier: earlier) { try reorderTask(task.id, relativeTo: target.id, after: !earlier) }
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
    func deleteTask(_ task: WorkTask) async throws {
        guard deletingTasks.insert(task.id).inserted else { return }
        defer { deletingTasks.remove(task.id) }
        try await core.deleteTask(task.id)
        if destination == .task(task.id) { destination = .project(task.projectId, .tasks) }
        backHistory.removeAll { $0 == .task(task.id) }
        forwardHistory.removeAll { $0 == .task(task.id) }
        if editingTask?.id == task.id { editingTask = nil }
        if priorityDrag?.taskID == task.id { priorityDrag = nil }
        chatDrafts[task.id] = nil; attachmentDrafts[task.id] = nil
        await refresh()
    }
    func add(_ discovered: DiscoveredProject) throws {
        guard !snapshot.repositories.contains(where: { !$0.removed && $0.repoPath == discovered.project.repoPath }) else { throw CoreError.invalid("This clone is already a project.") }
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
    func createTask(projectID: UUID, title: String, description: String, proofRequirement: ProofRequirement = .automatic, askBeforeBuild: Bool? = nil, files: [URL] = [], repositoryID: UUID? = nil) async throws {
        var resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTitle.isEmpty || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalid("Describe what you would like built.")
        }
        let needsTitle = resolvedTitle.isEmpty
        if needsTitle { resolvedTitle = Orchestrator.provisionalTitle(description) }
        try Task.checkCancellation()
        let task = try store.createTask(projectId: projectID, title: resolvedTitle, description: description, proofRequirement: proofRequirement, askBeforeBuild: askBeforeBuild, files: files, repositoryID: repositoryID)
        snapshot.tasks.append(task)
        showNewTask = false; destination = .task(task.id)
        if needsTitle { await core.refineTitle(of: task) }
        Task { await core.tick() }
    }
    func editTask(_ id: UUID, title: String, description: String, proofRequirement: ProofRequirement) async throws {
        try await core.editTask(id, title: title, description: description, proofRequirement: proofRequirement)
        await refresh()
    }
    func refineInChat(_ task: WorkTask) {
        destination = .project(task.projectId, .chat)
        perform { try await self.core.sendProjectMessage(task.projectId, text: "Help me refine this task: \(task.title) (task ID \(task.id)). Ask about unclear requirements, then update its description with refine_task. If coding has already started, pause it for replanning.") }
    }
    func pauseAll() throws { var value = try store.settings(); value.paused.toggle(); try store.saveSettings(value); Task { await core.tick() } }
    func renameProject(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CoreError.invalid("Enter a project name.") }
        var project = try store.get(Project.self, id)
        project.name = name
        try store.save(project)
        if let index = snapshot.projects.firstIndex(where: { $0.id == id }) { snapshot.projects[index] = project }
        snapshot.projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func pauseProject(_ project: Project) throws {
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
        else if let id = value["project"].flatMap(UUID.init(uuidString:)), snapshot.projects.contains(where: { $0.id == id }), value["page"] != nil { destination = .project(id, value["page"].flatMap(ProjectPage.init(rawValue:)) ?? .tasks) }
    }

    var installedEditors: [InstalledApp] {
        [("Cursor", "com.todesktop.230313mzl4w4u92"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Xcode", "com.apple.dt.Xcode")].compactMap { name, id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { InstalledApp(id: id, name: name, url: $0) }
        }
    }
    var defaultEditor: InstalledApp? {
        installedEditors.first { $0.id == selectedProject?.settings.editor } ?? installedEditors.first
    }
    func setEditor(_ id: String) throws {
        guard let projectID = selectedProject?.id else { return }
        var project = try store.get(Project.self, projectID)
        project.settings.editor = id; try store.save(project); try store.workflow(for: project)
    }
    func openLocation(task: WorkTask? = nil, appID: String? = nil, file: String? = nil) {
        let selected = task ?? selectedTask
        let path = selected?.worktreePath ?? (selected == nil ? selectedProject.flatMap { repositories($0.id).first?.repoPath } : nil)
        perform {
            guard let path else { throw CoreError.invalid("This task has no available worktree.") }
            let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            let url = file.map { root.appending(path: $0).resolvingSymlinksInPath() } ?? root
            guard url.path == root.path || url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
                throw CoreError.invalid("This file or worktree is no longer available.")
            }
            if let appID {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { throw CoreError.invalid("The selected app is not installed.") }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
            } else if !NSWorkspace.shared.open(url) { throw CoreError.invalid("The location could not be opened in Finder.") }
        }
    }
    func runPreview(_ task: WorkTask) {
        if snapshot.projects.first(where: { $0.id == task.projectId })?.settings.previewCommand.isEmpty != false {
            reviewSheet = .previewSetup(task.projectId); return
        }
        perform {
            let url = try await self.core.startPreview(task.id)
            guard NSWorkspace.shared.open(url) else { throw CoreError.invalid("The preview is ready, but your browser could not be opened.") }
        }
    }
}

struct InstalledApp: Identifiable {
    let id: String
    let name: String
    let url: URL
}
enum ReviewSheet: Identifiable {
    case changes(UUID), previewSetup(UUID), defaults(UUID), log(String), image(String)
    var id: String { String(describing: self) }
}
