import Foundation
import GRDB

struct BackgroundIssue: Identifiable, Equatable, Sendable {
    var id: String
    var message: String
    var taskID: UUID?
    var projectID: UUID?
}

actor Orchestrator {
    var modelCatalogues: [AgentProvider: [AgentModel]] = [:]
    let store: Store
    let runner: ProcessRunner
    private var loop: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: any AgentRunner] = [:]
    private var polling: Set<UUID> = []
    private var lastPoll: [UUID: Date] = [:]
    private var hostJobs: [UUID: Task<Void, Never>] = [:]
    var proofsRunning = 0
    var previews: [UUID: PreviewStatus] = [:]
    var previewProcesses: [UUID: ChildProcess] = [:]
    var previewJobs: [UUID: Task<URL, Error>] = [:]
    var previewMonitors: [UUID: Task<Void, Never>] = [:]
    private var openingPRs: Set<UUID> = []
    var editingTasks: Set<UUID> = []
    private var ticking = false
    private var lastDispatchWasChat = false
    var titleJobs: [UUID: Task<Void, Never>] = [:]
    var chatJobs: [UUID: Task<Void, Never>] = [:]
    var chatClients: [UUID: any AgentRunner] = [:]
    var shuttingDown = false
    private(set) var backgroundIssues: [String: BackgroundIssue] = [:]
    private var dismissedIssues: [String: String] = [:]
    func dismissBackgroundIssue(_ id: String) {
        dismissedIssues[id] = backgroundIssues[id]?.message
        backgroundIssues[id] = nil
    }
    private func clearBackgroundIssue(_ id: String) {
        backgroundIssues[id] = nil; dismissedIssues[id] = nil
    }
    func reportBackgroundIssue(_ message: String, id: String, taskID: UUID? = nil, projectID: UUID? = nil) {
        let text = runner.redacted(message)
        guard dismissedIssues[id] != text else { return }
        backgroundIssues[id] = BackgroundIssue(id: id, message: text, taskID: taskID, projectID: projectID)
    }
    var accountUsage: [AgentProvider: UsageSnapshot] = [:]
    var usageOverrides: Set<AgentProvider> = []
    var usageRefreshDates: [AgentProvider: Date] = [:]
    var usageRefreshJobs: [AgentProvider: Task<Void, Never>] = [:]
    var usageClients: [AgentProvider: any AgentRunner] = [:]
    var usage: UsageSnapshot { accountUsage[.codex] ?? UsageSnapshot() }

    init(store: Store, runner: ProcessRunner = ProcessRunner()) {
        self.store = store; self.runner = runner
    }
    func refineTitle(of task: WorkTask) {
        guard !shuttingDown else { return }
        titleJobs[task.id] = Task {
            defer { titleJobs[task.id] = nil }
            let provider = (try? configuredProvider(for: task.id)) ?? .codex
            let title = await generateTitle(for: task.description, provider: provider)
            guard !Task.isCancelled else { return }
            // Only replace the original provisional title; preserve concurrent lifecycle changes.
            try? await store.db.write { db in
                try db.execute(sql: "UPDATE task SET title = ? WHERE id = ? AND title = ? AND description = ?",
                               arguments: [title, task.id, task.title, task.description])
            }
        }
    }
    func start() async {
        guard loop == nil else { return }
        shuttingDown = false
        await refreshUsage()
        guard !shuttingDown else { return }
        do { try recover(); clearBackgroundIssue("recovery") }
        catch { reportBackgroundIssue(error.localizedDescription, id: "recovery"); return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func recover() throws {
        for task in try store.all(WorkTask.self) where task.state == .done { try store.removeMergedTaskAttachments(task.id) }
        for project in try store.all(Project.self) { try store.removeCompletedProjectAttachments(project.id) }
        for var attempt in try store.all(RunAttempt.self) where attempt.status == "running" {
            attempt.status = "failed"; attempt.error = "App stopped during attempt; resuming durable thread"; attempt.endedAt = Date()
            try store.save(attempt)
        }
        for var session in try store.all(Session.self) where session.status == "running" || session.status == "waiting" {
            session.status = session.ownerType == "project" ? "interrupted" : "idle"; session.currentTurn = nil; try store.save(session)
        }
        for session in try store.all(Session.self) { try interruptSubagents(session.id) }
    }
    func shutdown() async {
        shuttingDown = true
        for id in Array(previews.keys) { await stopPreview(id) }
        let naming = Array(titleJobs.values)
        for job in naming { job.cancel() }
        for job in naming { await job.value }
        for job in usageRefreshJobs.values { job.cancel() }
        for client in usageClients.values { await client.stop() }
        for job in usageRefreshJobs.values { await job.value }
        loop?.cancel(); loop = nil
        let hosted = Array(hostJobs.values)
        for job in hosted { job.cancel() }
        for job in hosted { await job.value }
        for id in Array(chatJobs.keys) { await stopProjectChat(id) }
        let pending = Array(workers.values)
        for worker in pending { worker.cancel() }
        for client in clients.values { await client.stop() }
        for worker in pending { await worker.value }
    }
    func tick(now: Date = Date()) async {
        guard !ticking, !shuttingDown else { return }
        ticking = true; defer { ticking = false }
        for provider in AgentProvider.allCases {
            let snapshot = accountUsage[provider] ?? UsageSnapshot()
            if now.timeIntervalSince(usageRefreshDates[provider] ?? .distantPast) >= 60, !snapshot.refreshing {
                usageRefreshDates[provider] = now
                if snapshot.updatedAt == nil { await refreshUsage(provider: provider) }
                else { usageRefreshJobs[provider] = Task { await refreshUsage(provider: provider) } }
            }
        }

        do {
            let initialSettings = try store.settings()
            let initialTasks = try store.all(WorkTask.self)
            let initialProjects = Dictionary(uniqueKeysWithValues: try store.all(Project.self).map { ($0.id, $0) })
            await withTaskGroup(of: Void.self) { group in
                for task in initialTasks {
                    guard let worker = workers[task.id], let project = initialProjects[task.projectId] else { continue }
                    let unroutable = (try? dependenciesReady(task)) != true
                    let humanWait = (try? openQuestions(task.id)) == true || (try? pendingPlan(task.id)) == true
                    if initialSettings.paused || project.paused || task.paused || task.state.terminal || unroutable || humanWait {
                        let client = clients[task.id]
                        let session = try? store.session(for: task.id)
                        group.addTask {
                            if let client, let thread = session?.providerSessionID, let turn = session?.currentTurn {
                                await client.interrupt(thread: thread, turn: turn)
                            }
                            worker.cancel()
                            await client?.stop()
                            await worker.value
                        }
                    }
                }
            }
            // Actor reentrancy permits edits while interruption waits. Never dispatch an old snapshot.
            guard !shuttingDown else { return }
            var settings = try store.settings()
            settings.agentsAtOnce = Self.computeCapacity(settings.agentsAtOnce)
            let tasks = try store.all(WorkTask.self)
            let projects = Dictionary(uniqueKeysWithValues: try store.all(Project.self).map { ($0.id, $0) })
            for task in tasks where !editingTasks.contains(task.id) && hostJobs[task.id] == nil && !polling.contains(task.id) && !openingPRs.contains(task.id) && now.timeIntervalSince(lastPoll[task.id] ?? .distantPast) >= 15 {
                let project = try? store.project(for: task)
                let watch = try watch(task.id)
                let publish = task.state == .humanReview && !task.paused && !settings.paused && project?.paused == false && project?.host.supportsPullRequests == true
                    && (project?.settings.askBeforeOpenPR == false || watch.repairing && watch.requirementsRevision == task.requirementsRevision)
                let observe = task.pr != nil && (!task.state.terminal || task.state == .done && task.worktreePath != nil)
                guard publish || observe else { continue }
                lastPoll[task.id] = now
                hostJobs[task.id] = Task {
                    if publish {
                        do { try await openPullRequest(task.id) }
                        catch is CancellationError { }
                        catch { reportBackgroundIssue(runner.redacted(error.localizedDescription), id: "pr-\(task.id)", taskID: task.id) }
                    } else { await pollPR(task.id) }
                    hostJobs[task.id] = nil
                }
            }
            await reconcileProjectChats(settings: settings, projects: projects)
            for project in projects.values where (try? project.settings.validate()) != nil {
                clearBackgroundIssue("project-\(project.id)")
            }
            guard !settings.paused else {
                clearBackgroundIssue("scheduler"); return
            }
            guard settings.agentsAtOnce > 0, settings.heavyStepsAtOnce > 0 else { throw CoreError.invalid("Concurrency limits must be positive") }
            // Waiting processes have been interrupted above; answers resume their durable thread in a free slot.
            var occupied = workers.count + chatJobs.count
            if !lastDispatchWasChat {
                let before = occupied
                occupied = try dispatchProjectChats(occupied: occupied, settings: settings, projects: projects, maximum: 1)
                if occupied > before { lastDispatchWasChat = true }
            }
            let dependents = Dictionary(grouping: tasks.flatMap { $0.dependsOn }, by: { $0 }).mapValues(\.count)
            let ordered = tasks.sorted {
                let aged0 = now.timeIntervalSince($0.updatedAt) > 600, aged1 = now.timeIntervalSince($1.updatedAt) > 600
                if aged0 != aged1 { return aged0 }
                if ($0.pr != nil) != ($1.pr != nil) { return $0.pr != nil }
                if $0.rank != $1.rank { return $0.rank > $1.rank }
                if dependents[$0.id, default: 0] != dependents[$1.id, default: 0] { return dependents[$0.id, default: 0] > dependents[$1.id, default: 0] }
                return $0.createdAt < $1.createdAt
            }
            for task in ordered {
                guard occupied < settings.agentsAtOnce else { break }
                guard try !usageBlocksDispatch(provider: configuredProvider(for: task.id)), workers[task.id] == nil, !scopeIsBusy(task), !editingTasks.contains(task.id), let project = try? store.project(for: task), !project.paused, !task.paused,
                      [.todo, .building].contains(task.state), (task.retry?.dueAt ?? .distantPast) <= now,
                      (try? dependenciesReady(task)) == true, !(try pendingPlan(task.id)), !(try openQuestions(task.id)) else { continue }
                do { try project.settings.validate(); clearBackgroundIssue("project-\(project.id)") }
                catch { reportBackgroundIssue(error.localizedDescription, id: "project-\(project.id)", projectID: project.id); continue }
                occupied += 1; lastDispatchWasChat = false
                workers[task.id] = Task { await run(task.id) }
            }
            let beforeChats = occupied
            occupied = try dispatchProjectChats(occupied: occupied, settings: settings, projects: projects)
            if occupied > beforeChats { lastDispatchWasChat = true }
            clearBackgroundIssue("scheduler")
        } catch { reportBackgroundIssue(error.localizedDescription, id: "scheduler") }
    }
    /// Bounded, redacted scheduler diagnostics shared with project chat and saved-message receipts.
    func waitingReason(_ task: WorkTask) throws -> String? {
        let settings = try store.settings(), project = try store.project(for: task)
        if task.state.terminal { return "This task is finished. Create a follow-up task for new work." }
        if task.paused { return "Task is paused. Resume it to continue." }
        if settings.paused { return "All work is paused. Resume agents to continue." }
        if project.paused { return "Project is paused. Resume it to start queued work." }
        if try openQuestions(task.id) { return "Waiting for your answer to the task’s question." }
        if try pendingPlan(task.id) { return "Waiting for your approval of the plan." }
        if task.state == .humanReview { return project.publicationBlockReason ?? "Waiting for human review." }
        if task.state == .inPR { return "Waiting for pull request review and CI." }
        if let retry = task.retry, retry.dueAt > Date() { return "Retry scheduled: " + runner.redacted(retry.error) }
        if try !dependenciesReady(task) { return "Waiting for prerequisite tasks to finish." }
        if workers[task.id] != nil { return nil }
        if editingTasks.contains(task.id) { return "Waiting for the task edit to finish." }
        if scopeIsBusy(task) { return "Another agent is changing overlapping files." }
        if try usageBlocksDispatch(provider: configuredProvider(for: task.id)) { return "Account usage is holding new work. Check usage in the agent menu." }
        return "Queued for the next available agent."
    }

    func scopeIsBusy(_ task: WorkTask) -> Bool {
        guard !task.affectedPaths.isEmpty else { return false }
        return workers.keys.contains { id in
            guard id != task.id, let other = try? store.get(WorkTask.self, id) else { return false }
            return task.overlaps(other)
        }
    }
    static func computeCapacity(_ requested: Int) -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return min(requested, 1)
        case .serious: return max(1, min(requested / 2, max(1, ProcessInfo.processInfo.activeProcessorCount / 4)))
        default: return requested
        }
    }
    func dependenciesReady(_ task: WorkTask) throws -> Bool {
        for id in Set(task.dependsOn + (task.stackOn.map { [$0] } ?? [])) {
            guard let dependency = try? store.get(WorkTask.self, id) else { return false }
            guard dependency.projectId == task.projectId else { return false }
            if task.stackOn == id && (task.repositoryID ?? task.projectId) != (dependency.repositoryID ?? dependency.projectId) { return false }
            if dependency.state != .done && !(task.stackOn == id && dependency.state == .inPR && dependency.pr != nil) { return false }
        }
        return true
    }
    private func pendingPlan(_ id: UUID) throws -> Bool {
        try store.all(Approval.self).contains { $0.taskId == id && $0.kind == "plan" && $0.status == "pending" }
    }
    private func openQuestions(_ id: UUID) throws -> Bool {
        try store.all(Question.self).contains { $0.taskId == id && $0.blocking && $0.answer == nil }
    }
    func planApproved(_ task: WorkTask, project: Project) throws -> Bool {
        if !(task.askBeforeBuild ?? project.settings.askBeforeBuild) { return true }
        return try store.all(Approval.self).contains { $0.taskId == task.id && $0.kind == "plan" && $0.status == "approved" }
    }
    func transition(_ id: UUID, to state: TaskState, merged: Bool = false) throws {
        var task = try store.get(WorkTask.self, id)
        let project = try store.project(for: task)
        let proof = try store.all(Proof.self).first { $0.taskId == id }
        try TransitionRules.validate(from: task.state, to: state, proofComplete: proof?.complete == true,
                                     questionsAnswered: !openQuestions(id), dependenciesReady: dependenciesReady(task),
                                     planApproved: planApproved(task, project: project), merged: merged)
        task.state = state; task.updatedAt = Date(); if state == .done { task.doneAt = Date() }
        let session = try store.session(for: id)
        try store.db.write { db in
            try task.save(db)
            try Message(sessionId: session.id, role: "system", kind: "event", body: "Moved to \(state.rawValue)").insert(db)
        }
    }
    func pause(_ id: UUID, paused: Bool) async throws {
        guard !editingTasks.contains(id) else { throw CoreError.invalid("Wait for the task edit to finish.") }
        var task = try store.get(WorkTask.self, id)
        if task.paused && !paused {
            let session = try store.session(for: id)
            try store.save(Message(sessionId: session.id, role: "system", kind: "event", body: "Work resumed by you."))
            task.retry = nil
        }
        task.paused = paused; try store.save(task)
        await tick()
    }
    func stopForReshape(_ id: UUID) async {
        await stopPreview(id)
        if let worker = workers[id] {
            worker.cancel(); await clients[id]?.stop(); await worker.value
        }
    }
    func editTask(_ id: UUID, title: String, description: String, proofRequirement: ProofRequirement, automaticallyResume: Bool = false, forceRevision: Bool = false, configuration: AgentConfiguration? = nil) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoreError.invalid("A task title cannot be empty.") }
        guard editingTasks.insert(id).inserted else { throw CoreError.invalid("This task is already being edited.") }
        defer { editingTasks.remove(id) }
        while polling.contains(id) { try await Task.sleep(for: .milliseconds(50)) }
        titleJobs[id]?.cancel()
        var task = try store.get(WorkTask.self, id)
        let selectedConfiguration: AgentConfiguration?
        if let configuration {
            let provider = try configuredProvider(for: id)
            let choice = try AgentModel.resolve(modelCatalogues[provider] ?? [], model: configuration.model, effort: configuration.effort)
            selectedConfiguration = AgentConfiguration(id: id, model: choice.model, effort: choice.effort, provider: provider)
        } else { selectedConfiguration = nil }
        let explicitlyPaused = task.paused
        let scopeChanged = forceRevision || task.description != description || task.proofRequirement != proofRequirement
        guard scopeChanged || task.title != title || selectedConfiguration != nil else { return }
        if scopeChanged {
            guard !task.state.terminal, (task.state != .inPR || automaticallyResume), !openingPRs.contains(id) else {
                throw CoreError.invalid("Only the title can be edited after a pull request is opening or the task is finished.")
            }
            if task.pr != nil {
                let project = try store.project(for: task)
                _ = try await project.pullRequestHost(runner: runner, root: store.root).verifiedOpenPR(task: task, project: project)
            }
            await stopPreview(id)
            if task.worktreePath != nil || workers[id] != nil {
                task.paused = true; try store.save(task)
                if let worker = workers[id] {
                    let client = clients[id]
                    let session = try store.session(for: id)
                    if let client, let thread = session.providerSessionID, let turn = session.currentTurn {
                        await client.interrupt(thread: thread, turn: turn)
                    }
                    worker.cancel(); await client?.stop(); await worker.value
                }
                task = try store.get(WorkTask.self, id)
                // Replan atomically below, only after the old worker can no longer publish proof.
                task.state = .todo
                task.paused = automaticallyResume ? explicitlyPaused : true
            }
            task.retry = nil
            task.requirementsRevision += 1
        }
        task.title = title; task.description = description; task.proofRequirement = proofRequirement; task.updatedAt = Date()
        let edited = task
        try await store.db.write { db in
            if let selectedConfiguration { try selectedConfiguration.save(db) }
            if scopeChanged {
                try edited.save(db)
                try db.execute(sql: "UPDATE proof SET complete = 0 WHERE taskId = ?", arguments: [id])
                try db.execute(sql: "UPDATE approval SET status = 'superseded', resolvedAt = ? WHERE taskId = ? AND kind = 'plan'", arguments: [Date(), id])
                try db.execute(sql: "UPDATE question SET answer = 'Superseded by task edit', answeredBy = 'taskEdit', answeredAt = ? WHERE taskId = ? AND answer IS NULL", arguments: [Date(), id])
            } else {
                // A running worker may advance while this write is queued. Preserve its lifecycle fields.
                try db.execute(sql: "UPDATE task SET title = ?, updatedAt = ? WHERE id = ?", arguments: [edited.title, edited.updatedAt, id])
            }
            if let session = try Session.filter(Column("ownerType") == "task" && Column("ownerId") == id).fetchOne(db) {
                let body = scopeChanged ? "Task brief or proof updated. Previous proof and plans are superseded." : (selectedConfiguration == nil ? "Task title updated." : "Task settings updated.")
                try Message(sessionId: session.id, role: "system", kind: "event", body: body).insert(db)
            }
        }
        if automaticallyResume { editingTasks.remove(id); await tick() }
    }
    func answer(_ id: UUID, text: String, useSuggested: Bool = false, files: [URL] = []) async throws {
        var question = try store.get(Question.self, id)
        guard question.answer == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("Question is answered or answer is empty") }
        guard question.allowsFreeText || question.options.contains(text) else { throw CoreError.invalid("Choose an offered answer") }
        if useSuggested, question.suggestedAnswer != text { throw CoreError.invalid("The suggested answer changed. Review it again.") }
        if !files.isEmpty {
            let task = try store.get(WorkTask.self, question.taskId)
            let session = try store.session(for: task.id)
            let message = Message(sessionId: session.id, role: "user", body: text)
            let attachments = try store.saveChatMessage(message, files: files, projectID: task.projectId, ownerID: task.id)
            if let client = clients[task.id], let thread = session.providerSessionID, let turn = session.currentTurn {
                try await client.steer(session: thread, turn: turn, text: "Reference files for my answer: " + text, attachments: attachments)
                try store.acknowledgeInput(session: session, ids: [message.id] + attachments.map(\.id))
            }
        }
        question.answer = text; question.answeredAt = Date(); question.answeredBy = useSuggested ? "agentDefault" : "user"; try store.save(question)
        if !question.blocking {
            let session = try store.session(for: question.taskId)
            if let client = clients[question.taskId], let thread = session.providerSessionID, let turn = session.currentTurn {
                try await client.steer(session: thread, turn: turn, text: "Answer to \(question.prompt): \(text)", attachments: [])
                try store.acknowledgeInput(session: session, ids: [question.id])
            }
        }
        let task = try store.get(WorkTask.self, question.taskId)
        if try task.state == .needsClarification && !openQuestions(task.id) {
            let project = try store.project(for: task)
            let ready = try dependenciesReady(task) && planApproved(task, project: project)
            try transition(task.id, to: ready ? .building : .todo)
        }
        await tick()
    }
    func approvePlan(_ id: UUID) async throws {
        var approval = try store.get(Approval.self, id)
        guard approval.kind == "plan", approval.status == "pending" else { throw CoreError.invalid("No pending plan") }
        approval.status = "approved"; approval.resolvedAt = Date(); try store.save(approval)
        if try dependenciesReady(store.get(WorkTask.self, approval.taskId)) { try transition(approval.taskId, to: .building) }
        await tick()
    }
    private func requestChanges(_ id: UUID, note: String, files: [URL]) async throws {
        guard files.count <= 20 else { throw CoreError.invalid("Attach up to 20 files per message.") }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty || !files.isEmpty else { throw CoreError.invalid("Describe the changes you want.") }
        guard !openingPRs.contains(id), editingTasks.insert(id).inserted else { throw CoreError.invalid("Wait for the current task action to finish.") }
        defer { editingTasks.remove(id) }
        while polling.contains(id) { try await Task.sleep(for: .milliseconds(50)) }
        let current = try store.get(WorkTask.self, id)
        guard [.humanReview, .inPR].contains(current.state) else { throw CoreError.invalid("Only a task awaiting review or in an open pull request can receive review feedback.") }
        if current.pr != nil {
            let project = try store.project(for: current)
            _ = try await project.pullRequestHost(runner: runner, root: store.root).verifiedOpenPR(task: current, project: project)
            clearBackgroundIssue("pr-\(id)")
        }
        await stopPreview(id)
        if let worker = workers[id] { worker.cancel(); await clients[id]?.stop(); await worker.value }
        let session = try store.session(for: id)
        let projectID = try store.get(WorkTask.self, id).projectId
        let message = Message(sessionId: session.id, role: "user", body: note)
        let attachments = try store.prepareAttachments(files, projectID: projectID, ownerID: id, messageID: message.id)
        do { try await store.db.write { db in
            guard var task = try WorkTask.fetchOne(db, key: id), [.humanReview, .inPR].contains(task.state) else { throw CoreError.invalid("The task is no longer available for review feedback.") }
            task.state = .building; task.retry = nil; task.updatedAt = Date(); task.requirementsRevision += 1
            try task.save(db)
            try db.execute(sql: "UPDATE proof SET complete = 0 WHERE taskId = ?", arguments: [id])
            try message.insert(db)
            for attachment in attachments { try attachment.insert(db) }
            try Message(sessionId: session.id, role: "system", kind: "event", body: "Review feedback received. Fresh proof is required.").insert(db)
        }
        } catch { store.discardPreparedAttachments(attachments); throw error }
        editingTasks.remove(id)
        await tick()
    }
    @discardableResult
    func steer(_ id: UUID, text: String, files: [URL] = []) async throws -> MessageDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { throw CoreError.invalid("Enter a message or attach a file.") }
        if try [.humanReview, .inPR].contains(store.get(WorkTask.self, id).state) {
            try await requestChanges(id, note: text, files: files)
            return .queued
        }
        let session = try store.session(for: id)
        let message = Message(sessionId: session.id, role: "user", body: text)
        let attachments = try store.saveChatMessage(message, files: files, projectID: store.get(WorkTask.self, id).projectId, ownerID: id)
        if let client = clients[id], let thread = session.providerSessionID, let turn = session.currentTurn {
            try await client.steer(session: thread, turn: turn, text: text, attachments: attachments)
            try store.acknowledgeInput(session: session, ids: [message.id] + attachments.map(\.id))
            return .sent
        }
        await tick()
        let current = try store.get(WorkTask.self, id)
        if workers[id] != nil { return .queued }
        if let reason = try waitingReason(current) {
            try store.save(Message(sessionId: session.id, role: "system", body: "Message saved. " + reason))
        }
        return .saved
    }
    func openPullRequest(_ id: UUID) async throws {
        guard !shuttingDown, !Task.isCancelled, !editingTasks.contains(id) else { throw CoreError.invalid("Wait for the task edit to finish.") }
        let task = try store.get(WorkTask.self, id)
        guard openingPRs.insert(id).inserted else { throw CoreError.invalid("Pull request is already opening") }
        defer { openingPRs.remove(id) }
        guard task.state == .humanReview, !task.paused else { throw CoreError.invalid("Task is not ready for a PR") }
        guard let proof = try store.all(Proof.self).first(where: { $0.taskId == id && $0.complete }) else { throw CoreError.invalid("Proof is incomplete") }
        guard let cwd = task.worktreePath else { throw CoreError.invalid("The worktree is unavailable.") }
        await stopPreview(id)
        let head = try await runner.run("git", ["rev-parse", "HEAD"], cwd: cwd).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = try await runner.run("git", ["status", "--porcelain"], cwd: cwd).output.isEmpty
        guard clean, proof.commitSHA == head, proof.requirementsRevision == task.requirementsRevision else { throw CoreError.invalid("The worktree or requirements changed since proof was recorded. Ask the agent in chat for fresh proof before opening a pull request.") }
        let project = try store.project(for: task)
        if let reason = project.publicationBlockReason { throw CoreError.invalid(reason) }
        var base = project.defaultBranch
        if let parentId = task.stackOn {
            let parent = try store.get(WorkTask.self, parentId)
            guard (parent.repositoryID ?? parent.projectId) == (task.repositoryID ?? task.projectId) else { throw CoreError.invalid("Stacked tasks must use the same repository.") }
            if parent.state != .done {
                guard let branch = parent.branchName, parent.pr != nil else { throw CoreError.invalid("Stack base has no pull request") }
                base = branch
            }
        }
        let pr = try await project.pullRequestHost(runner: runner, root: store.root).open(task: task, project: project, summary: proof.summary, base: base, commitSHA: head)
        clearBackgroundIssue("pr-\(id)")
        var current = try store.get(WorkTask.self, id)
        current.pr = pr; try store.save(current)
        try transition(id, to: .inPR)
        try await finishHostedPass(store.get(WorkTask.self, id), project: project)
    }
    func pollPR(_ id: UUID) async {
        guard !shuttingDown, !Task.isCancelled, !editingTasks.contains(id), !openingPRs.contains(id), polling.insert(id).inserted else { return }
        defer { polling.remove(id) }
        do {
            let task = try store.get(WorkTask.self, id)
            let project = try store.project(for: task)
            let status = try await project.pullRequestHost(runner: runner, root: store.root).status(task: task, project: project)
            guard !editingTasks.contains(id), !openingPRs.contains(id) else { return }
            if status.state == "MERGED", !task.state.terminal, task.state != .inPR {
                var paused = try store.get(WorkTask.self, id); paused.paused = true
                paused.retry = Retry(attempt: 0, dueAt: Date(), error: "The PR merged while this task had further work. The worktree is preserved; create a follow-up for unpublished changes.")
                try store.save(paused); await stopForReshape(id); return
            }
            if task.state == .inPR, status.state == "MERGED" {
                guard !editingTasks.contains(id), try store.get(WorkTask.self, id).state == .inPR else { return }
                try transition(id, to: .done, merged: true)
            }
            if status.state == "OPEN", task.state == .inPR {
                try await finishHostedPass(task, project: project)
                try await reconcileHostedReview(task, project: project, status: status)
            } else if status.state == "CLOSED", !task.state.terminal {
                var paused = try store.get(WorkTask.self, id); paused.paused = true; try store.save(paused)
                await stopForReshape(id)
                throw CoreError.invalid("This PR was closed without merging. Review the host decision before continuing.")
            }
            guard !editingTasks.contains(id) else { return }
            let merged = try store.get(WorkTask.self, id)
            if merged.state == .done {
                try store.removeMergedTaskAttachments(id)
                try store.removeCompletedProjectAttachments(project.id)
            }
            if merged.state == .done, merged.worktreePath != nil, workers[id] == nil {
                await stopPreview(id)
                do {
                    try await Workspace(store: store, runner: runner).remove(merged, project: project)
                    try await store.db.write { db in
                        try db.execute(sql: "UPDATE task SET worktreePath = NULL, workspaceReady = 0 WHERE id = ?", arguments: [id])
                    }
                    clearBackgroundIssue("cleanup-\(id)")
                } catch { reportBackgroundIssue("Worktree cleanup: " + error.localizedDescription, id: "cleanup-\(id)", taskID: id) }
            }
            clearBackgroundIssue("pr-\(id)")
        } catch { reportBackgroundIssue(error.localizedDescription, id: "pr-\(id)", taskID: id) }
    }
    func deleteTask(_ id: UUID) async throws {
        guard editingTasks.insert(id).inserted else { throw CoreError.invalid("Wait for the current task action to finish.") }
        defer { editingTasks.remove(id) }
        var task = try store.get(WorkTask.self, id)
        task.paused = true; try store.save(task)
        let naming = titleJobs[id]
        naming?.cancel()
        if let worker = workers[id] {
            let client = clients[id]
            // Cancel first: closing the process unblocks RPCs without waiting for an agent response.
            worker.cancel(); await client?.stop(); await worker.value
        }
        await naming?.value
        await stopPreview(id)
        // An already-started publish/poll owns the worktree until its operation completes.
        // The edit lock prevents new publishes, previews, polls and agent dispatches.
        while openingPRs.contains(id) || polling.contains(id) {
            try await Task.sleep(for: .milliseconds(50))
        }
        task = try store.get(WorkTask.self, id)
        let project = try store.project(for: task)
        try await Workspace(store: store, runner: runner).remove(task, project: project, discardChanges: true)
        for path in [store.root.appending(path: "logs/\(id)"), store.root.appending(path: "projects/\(project.id)/media/\(id)")] {
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        let deletedTitle = task.title
        try await store.db.write { db in
            for var dependent in try WorkTask.fetchAll(db) where dependent.dependsOn.contains(id) || dependent.stackOn == id {
                dependent.dependsOn.removeAll { $0 == id }
                if dependent.stackOn == id { dependent.stackOn = nil }
                dependent.paused = true
                try dependent.save(db)
                let session = try Session.filter(Column("ownerType") == "task" && Column("ownerId") == dependent.id).fetchOne(db) ?? Session(ownerType: "task", ownerId: dependent.id)
                try session.save(db)
                try Message(sessionId: session.id, role: "system", kind: "event", body: "Paused because dependency ‘\(deletedTitle)’ was deleted. Review the task before resuming.").insert(db)
            }
            try db.execute(sql: "DELETE FROM attachment WHERE ownerType = 'message' AND ownerId IN (SELECT message.id FROM message JOIN session ON session.id = message.sessionId WHERE session.ownerType = 'task' AND session.ownerId = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM session WHERE ownerType = 'task' AND ownerId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM attachment WHERE ownerType = 'task' AND ownerId = ?", arguments: [id])
            _ = try AgentConfiguration.deleteOne(db, key: id)
            _ = try WorkTask.deleteOne(db, key: id)
        }
        lastPoll[id] = nil
        backgroundIssues = backgroundIssues.filter { $0.value.taskID != id }
        await tick()
    }
    func deleteProject(_ id: UUID) async throws {
        await stopProjectChat(id)
        let project = try store.get(Project.self, id)
        for repository in try store.repositories(id, includingRemoved: true) {
            let chatPath = chatWorkspace(project, repositoryID: repository.id).path
            if FileManager.default.fileExists(atPath: chatPath) {
                try Workspace(store: store, runner: runner).ensureOwned(chatPath)
                _ = try await runner.run("git", ["worktree", "remove", chatPath], cwd: repository.repoPath)
            }
        }
        let tasks = try store.all(WorkTask.self).filter { $0.projectId == id }
        guard tasks.allSatisfy({ workers[$0.id] == nil }) else { throw CoreError.invalid("Pause the project before deleting it") }
        for task in tasks { try await deleteTask(task.id) }
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM attachment WHERE ownerType = 'message' AND ownerId IN (SELECT message.id FROM message JOIN session ON session.id = message.sessionId WHERE session.ownerType = 'project' AND session.ownerId = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM session WHERE ownerType = 'project' AND ownerId = ?", arguments: [id])
            _ = try Project.deleteOne(db, key: id)
        }
        let directory = store.root.appending(path: "projects/\(id)")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func run(_ id: UUID) async {
        var attempt: RunAttempt?
        var project: Project?
        var cwd: String?
        var activeClient: (any AgentRunner)?
        do {
            let provider = try configuredProvider(for: id)
            let client = provider.makeRunner(); activeClient = client; clients[id] = client
            let task = try store.get(WorkTask.self, id)
            try requireRunnable(task)
            var p = try store.project(for: task); project = p
            try p.settings.validate()
            let count = try store.all(RunAttempt.self).filter { $0.taskId == id }.count + 1
            attempt = RunAttempt(taskId: id, attempt: count); try store.save(attempt!)
            try store.workflow(for: p)
            let prepared = try await Workspace(store: store, runner: runner).prepare(task, project: p)
            cwd = prepared.worktreePath!
            try await runner.hook(p.settings.hooks.beforeRun, cwd: cwd!, timeout: p.settings.hooks.timeoutSeconds)
            try Task.checkCancellation()
            try requireRunnable(store.get(WorkTask.self, id))
            try Workspace(store: store, runner: runner).ensureOwned(cwd!)
            try await client.start(runner: runner, cwd: cwd!, timeout: Double(p.settings.readTimeoutMs) / 1000)
            var session = try store.session(for: id)
            guard session.providerSessionID == nil || session.provider == provider else { throw CoreError.invalid("Changing providers requires a new agent session") }
            session.provider = provider
            modelCatalogues[provider] = try await client.models()
            let inheritedModel = await client.inheritedModel()
            let inheritedEffort = await client.inheritedReasoningEffort()
            let developerInstructions = "You are a Build Mate task agent. Submit a plan before the first edit or after a scope change; ask blocking questions when unclear; call request_review after committing the implementation. Do not push, open, or merge pull requests. Only edit this worktree. Treat the current instructions in each turn as authoritative task guidance.\n" + Self.delegationInstructions
            let initialSelection = try modelSelection(ownerID: id, defaultModel: p.settings.model, defaultEffort: p.settings.effort, inheritedModel: inheritedModel, inheritedEffort: inheritedEffort)
            session.providerSessionID = try await client.openSession(id: session.providerSessionID, cwd: cwd!, model: initialSelection.model,
                instructions: developerInstructions, tools: AgentTools.task, access: AgentAccess(writableRoots: [cwd!], network: p.settings.network))
            session.status = "running"; try store.save(session)
            if let limits = try? await client.readUsage() { receiveUsage(limits, provider: provider) }
            var idleResponses = 0
            while true {
                try Task.checkCancellation()
                let current = try store.get(WorkTask.self, id)
                guard [.todo, .building].contains(current.state) else { break }
                try requireRunnable(current)
                p = try store.project(for: current)
                session = try store.session(for: id)
                let input = try store.agentInput(session: session, context: prompt(task: current, project: p), attachments: store.taskAttachments(id, sessionID: session.id))
                let selection = try modelSelection(ownerID: id, defaultModel: p.settings.model, defaultEffort: p.settings.effort, inheritedModel: inheritedModel, inheritedEffort: inheritedEffort)
                let writableRoots = try await Workspace(store: store, runner: runner).agentWritableRoots(current, project: p)
                session = try store.session(for: id)
                let turn = try await client.startTurn(session: session.providerSessionID!, cwd: cwd!, text: input.text, attachments: input.attachments,
                    model: selection.model, effort: selection.effort, access: AgentAccess(writableRoots: writableRoots, network: p.settings.network))
                try store.acknowledgeInput(session: session, ids: input.ids, context: input.context)
                session.activeModel = selection.model; session.activeEffort = selection.effort
                session.currentTurn = turn; session.turnCount += 1; session.lastEventAt = Date(); try store.save(session)
                let started = SuspendingClock.now
                var waitingDuration = Duration.zero
                var complete = false
                var madeProgress = false
                var streaming: [String: UUID] = [:]
                while !complete {
                    try Task.checkCancellation()
                    guard started.duration(to: SuspendingClock.now) - waitingDuration < .milliseconds(p.settings.turnTimeoutMs) else { throw CoreError.invalid("Agent turn timed out") }
                    guard let event = try await client.nextAgentEvent() else {
                        let last = await client.lastEventAt
                        let runningCommand = await client.hasActiveCommands
                        guard runningCommand || p.settings.stallTimeoutMs <= 0 || last.duration(to: SuspendingClock.now) < .milliseconds(p.settings.stallTimeoutMs) else { throw CoreError.invalid("Agent stalled") }
                        guard started.duration(to: SuspendingClock.now) - waitingDuration < .milliseconds(p.settings.turnTimeoutMs) else { throw CoreError.invalid("Agent turn timed out") }
                        continue
                    }
                    session = try store.session(for: id); session.lastEventAt = Date(); try store.save(session)
                    let consumed = try await consumeAgentEvent(event, session: session, client: client, streaming: &streaming, includeCommands: false)
                    madeProgress = madeProgress || consumed.progress
                    if consumed.handled { continue }
                    switch event.kind {
                    case .request(let request):
                        let before = SuspendingClock.now
                        madeProgress = try await handleTaskRequest(request, taskId: id) || madeProgress
                        waitingDuration += before.duration(to: SuspendingClock.now)
                        let latest = try store.get(WorkTask.self, id)
                        if latest.state == .humanReview || latest.state == .inPR { complete = true }
                    case .turnCompleted(let status):
                        guard status == "completed" else { throw CoreError.invalid("Agent turn \(status)") }
                        complete = true
                    default: break
                    }

                }
                let latest = try store.get(WorkTask.self, id)
                if latest.state == .humanReview || latest.state == .inPR { break }
                idleResponses = madeProgress ? 0 : idleResponses + 1
                if idleResponses >= 3 {
                    var paused = latest; paused.paused = true
                    paused.retry = Retry(attempt: 0, dueAt: Date(), error: "The agent replied repeatedly without taking action. Review the conversation, then resume when ready.")
                    try store.save(paused)
                    throw CancellationError()
                }
                try await Task.sleep(for: .seconds(1))
            }
            attempt?.status = "succeeded"
            var finishedTask = try store.get(WorkTask.self, id); finishedTask.retry = nil; try store.save(finishedTask)
            clearBackgroundIssue("task-\(id)")
        } catch is CancellationError {
            attempt?.status = "canceled"
        } catch {
            let message = runner.redacted(error.localizedDescription)
            attempt?.status = message.contains("stalled") ? "stalled" : message.contains("timed out") ? "timedOut" : "failed"
            attempt?.error = message
            do {
                var task = try store.get(WorkTask.self, id)
                if !task.state.terminal && !task.paused {
                    let number = (task.retry?.attempt ?? 0) + 1
                    let delay = min(10 * pow(2, Double(min(number - 1, 20))), Double(project?.settings.retryBackoffMaxMs ?? 300_000) / 1000)
                    task.paused = number >= 3
                    task.retry = Retry(attempt: number, dueAt: Date().addingTimeInterval(delay), error: number >= 3 ? "The agent couldn’t continue after three attempts. " + message : message)
                    try store.save(task)
                }
            } catch { reportBackgroundIssue(error.localizedDescription, id: "task-\(id)", taskID: id) }
        }
        await activeClient?.stop()
        // Cleanup hooks must run even after cancellation of the worker task.
        if let p = project, let cwd {
            let runner = runner
            let result = await Task.detached { () -> String? in
                do { try await runner.hook(p.settings.hooks.afterRun, cwd: cwd, timeout: p.settings.hooks.timeoutSeconds); return nil }
                catch { return runner.redacted(error.localizedDescription) }
            }.value
            // Cleanup diagnostics must not rerun an already successful coding attempt.
            if let result { reportBackgroundIssue("After-run cleanup: " + result, id: "hook-\(id)", taskID: id) }
            else { clearBackgroundIssue("hook-\(id)") }
        }
        if var attempt { attempt.endedAt = Date(); try? store.save(attempt) }
        if var session = try? store.session(for: id) {
            try? interruptSubagents(session.id)
            session.status = "idle"; session.currentTurn = nil; try? store.save(session)
        }
        clients.removeValue(forKey: id); workers.removeValue(forKey: id)
    }

    private func requireRunnable(_ task: WorkTask) throws {
        let project = try store.project(for: task)
        guard !shuttingDown, !Task.isCancelled, !task.paused, !project.paused, !(try store.settings()).paused,
              !task.state.terminal, try dependenciesReady(task) else { throw CancellationError() }
    }

    private func prompt(task: WorkTask, project: Project) throws -> String {
        return "\(Self.hostedInstructions)\n\((try? watch(task.id).feedback.map { "Feedback ID: \($0.id)\n\($0.body)" }.joined(separator: "\n\n")) ?? "")\n\(Self.qaInstructions)\n\(Self.delegationInstructions)\nGlobal instructions:\n\(try store.settings().instructions)\nProject instructions (override global):\n\(project.instructions)\nTask #\(task.number): \(task.title)\n\(task.description)\nCurrent base commit: \(task.baseCommitSHA ?? "repository default"). Before final QA, ensure your branch incorporates this base; when a stacked parent merges, reconcile its changes rather than submitting them again. This current brief and proof preference supersede earlier versions of this task. Reassess the plan after an edit; use earlier answers only where they still apply.\n\(task.pr.map { "Continue work on existing PR #\($0.number) in this same worktree and branch. Ask a blocking question if the requested changes are unclear. After changes, commit and request fresh review; Build Mate updates the existing PR after review. The summary must describe the full branch change against the PR base, not just the latest feedback. Do not push or create another PR." } ?? "")\nProof preference: \(task.proofRequirement.title). Automatic means choose relevant evidence for this task: checks for functional work and a recording for visual work, respecting explicit user instructions in the brief. Checks only suppresses recordings; Checks + recording requires one. Explain the choice in your plan. Write the review summary as concise, readable Markdown describing the changes, using paragraphs and bullets where useful, never JSON. This summary becomes the PR body: include only what changed and why, with no proof reports, recording details, validation logs, commit hashes or Build Mate branding. Put evidence explanations in rationale and checks instead. At request_review supply summary, needsRecording, rationale, checks [{name, command}], and recordingCommand when needed. At least one relevant check must pass; documentation-only work may use a meaningful content or formatting check. The app independently executes these commands in the worktree. Visual screenshot requirement: \(project.settings.screenshotsForUI && task.proofRequirement != .checksOnly). For visual changes when enabled, supply screenshotsCommand writing before (default/base branch) and after PNGs to $BUILD_MATE_BEFORE_PATH and $BUILD_MATE_AFTER_PATH. All evidence output paths are app-owned. A recording command writes MP4/H.264 to $BUILD_MATE_RECORDING_PATH; do not write proof artifacts into the repository.\nDeclare affectedPaths in submit_plan when known so overlapping edits can be coordinated. Keep builds and tests proportionate to available compute and avoid redundant parallel heavy processes. Submit a plan before the first edit or after the brief changes; continue an accepted plan without submitting it again. Ask questions if unclear. Commit changes before request_review. The current sandbox permits staging and commits on your task branch, including its Git metadata outside the worktree. Retry earlier Git permission failures with these current permissions; do not change repository configuration, other branches, or the main checkout."
    }
    func waitForAnswer(_ question: Question) async throws -> String {
        while true {
            try Task.checkCancellation()
            if let answer = try store.get(Question.self, question.id).answer { return answer }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func ask(taskId: UUID, prompt: String, options: [String], allowsFreeText: Bool, blocking: Bool, suggestedAnswer: String? = nil) throws -> Question {
        guard !prompt.isEmpty else { throw CoreError.invalid("Question needs a prompt") }
        let session = try store.session(for: taskId)
        let message = Message(sessionId: session.id, role: "agent", kind: "question", body: prompt)
        let suggestion = suggestedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validSuggestion = suggestion.flatMap { !$0.isEmpty && (allowsFreeText || options.contains($0)) ? $0 : nil }
        let question = Question(taskId: taskId, messageId: message.id, prompt: prompt, options: options, allowsFreeText: allowsFreeText, blocking: blocking,
                                suggestedAnswer: validSuggestion)
        try store.db.write { db in try message.insert(db); try question.insert(db) }
        if blocking {
            let task = try store.get(WorkTask.self, taskId)
            if task.state != .needsClarification && task.state != .inPR { try transition(taskId, to: .needsClarification) }
        }
        return question
    }
}
