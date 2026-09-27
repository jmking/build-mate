import Foundation
import GRDB

struct BackgroundIssue: Identifiable, Equatable, Sendable {
    var id: String
    var message: String
    var taskID: UUID?
    var projectID: UUID?
}

actor Orchestrator {
    var availableModels: [CodexModel] = []
    let store: Store
    let runner: ProcessRunner
    private var loop: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: CodexClient] = [:]
    private var polling: Set<UUID> = []
    private var lastPoll: [UUID: Date] = [:]
    var proofsRunning = 0
    var previews: [UUID: PreviewStatus] = [:]
    var previewProcesses: [UUID: ChildProcess] = [:]
    var previewJobs: [UUID: Task<URL, Error>] = [:]
    var previewMonitors: [UUID: Task<Void, Never>] = [:]
    private var openingPRs: Set<UUID> = []
    var editingTasks: Set<UUID> = []
    private var ticking = false
    var titleJobs: [UUID: Task<Void, Never>] = [:]
    var chatJobs: [UUID: Task<Void, Never>] = [:]
    var chatClients: [UUID: CodexClient] = [:]
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
    private func reportBackgroundIssue(_ message: String, id: String, taskID: UUID? = nil, projectID: UUID? = nil) {
        let text = runner.redacted(message)
        guard dismissedIssues[id] != text else { return }
        backgroundIssues[id] = BackgroundIssue(id: id, message: text, taskID: taskID, projectID: projectID)
    }
    private(set) var rateLimits: JSON = .null
    private(set) var usage = UsageSnapshot()
    private var usageOverride = false
    func usageHeld() -> Bool {
        guard !usageOverride, let window = usage.limitingWindow else { return false }
        return window.remaining < ((try? store.settings().usageHoldThreshold) ?? 15)
    }
    func resumeDespiteUsage() async { usageOverride = true; await tick() }
    private var lastUsageRefresh = Date.distantPast
    private var usageRefresh: Task<Void, Never>?
    private var usageClient: CodexClient?

    init(store: Store, runner: ProcessRunner = ProcessRunner()) {
        self.store = store; self.runner = runner
    }
    func refineTitle(of task: WorkTask) {
        guard !shuttingDown else { return }
        titleJobs[task.id] = Task {
            defer { titleJobs[task.id] = nil }
            let title = await generateTitle(for: task.description)
            guard !Task.isCancelled else { return }
            // Only replace the original provisional title; preserve concurrent lifecycle changes.
            try? await store.db.write { db in
                try db.execute(sql: "UPDATE task SET title = ? WHERE id = ? AND title = ? AND description = ?",
                               arguments: [title, task.id, task.title, task.description])
            }
        }
    }
    private func receiveUsage(_ limits: JSON, replacing: Bool = true) {
        rateLimits = limits; usage.receive(limits, replacing: replacing)
        if let window = usage.limitingWindow, window.remaining >= ((try? store.settings().usageHoldThreshold) ?? 15) { usageOverride = false }
    }
    func refreshUsage() async {
        guard !usage.refreshing, !shuttingDown else { return }
        usage.refreshing = true; lastUsageRefresh = Date()
        let client = CodexClient()
        usageClient = client
        defer { usage.refreshing = false; usageClient = nil }
        do {
            // Account metadata only: no thread, turn, workspace or model request is created.
            try await client.start(runner: runner, cwd: store.root.path, timeout: 5)
            let limits = try await client.request("account/rateLimits/read", [:])
            receiveUsage(limits)
        } catch { usage.error = runner.redacted(error.localizedDescription) }
        await client.stop()
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
    }
    func shutdown() async {
        shuttingDown = true
        for id in Array(previews.keys) { await stopPreview(id) }
        let naming = Array(titleJobs.values)
        for job in naming { job.cancel() }
        for job in naming { await job.value }
        usageRefresh?.cancel()
        await usageClient?.stop()
        await usageRefresh?.value
        loop?.cancel(); loop = nil
        for id in Array(chatJobs.keys) { await stopProjectChat(id) }
        let pending = Array(workers.values)
        for worker in pending { worker.cancel() }
        for client in clients.values { await client.stop() }
        for worker in pending { await worker.value }
    }
    func tick(now: Date = Date()) async {
        guard !ticking, !shuttingDown else { return }
        ticking = true; defer { ticking = false }
        if now.timeIntervalSince(lastUsageRefresh) >= 60, !usage.refreshing {
            lastUsageRefresh = now
            if usage.updatedAt == nil { await refreshUsage() }
            else { usageRefresh = Task { await refreshUsage() } }
        }
        do {
            let initialSettings = try store.settings()
            let initialTasks = try store.all(WorkTask.self)
            let initialProjects = Dictionary(uniqueKeysWithValues: try store.all(Project.self).map { ($0.id, $0) })
            await withTaskGroup(of: Void.self) { group in
                for task in initialTasks {
                    guard let worker = workers[task.id], let project = initialProjects[task.projectId] else { continue }
                    let unroutable = (try? dependenciesReady(task)) != true
                    if initialSettings.paused || project.paused || task.paused || task.state.terminal || unroutable {
                        let client = clients[task.id]
                        let session = try? store.session(for: task.id)
                        group.addTask {
                            if let client, let thread = session?.codexThreadId, let turn = session?.currentTurn {
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
            let settings = try store.settings()
            let tasks = try store.all(WorkTask.self)
            let projects = Dictionary(uniqueKeysWithValues: try store.all(Project.self).map { ($0.id, $0) })
            for task in tasks where (task.state == .inPR || (task.state == .done && task.worktreePath != nil)) && !editingTasks.contains(task.id) && !polling.contains(task.id) && now.timeIntervalSince(lastPoll[task.id] ?? .distantPast) >= 60 {
                lastPoll[task.id] = now
                Task { await pollPR(task.id) }
            }
            await reconcileProjectChats(settings: settings, projects: projects)
            for project in projects.values where (try? project.settings.validate()) != nil {
                clearBackgroundIssue("project-\(project.id)")
            }
            guard !settings.paused, !usageHeld(), !(usage.refreshing && usage.updatedAt == nil) else {
                clearBackgroundIssue("scheduler"); return
            }
            guard settings.agentsAtOnce > 0, settings.heavyStepsAtOnce > 0 else { throw CoreError.invalid("Concurrency limits must be positive") }
            // A waiting worker still owns a process and a slot. Answering cannot overbook the limit.
            var occupied = workers.count + chatJobs.count
            occupied = try dispatchProjectChats(occupied: occupied, settings: settings, projects: projects)
            for task in tasks.sorted(by: { $0.rank == $1.rank ? $0.createdAt < $1.createdAt : $0.rank > $1.rank }) {
                guard occupied < settings.agentsAtOnce else { break }
                guard workers[task.id] == nil, !editingTasks.contains(task.id), let project = projects[task.projectId], !project.paused, !task.paused, project.runBlockReason == nil,
                      [.todo, .building].contains(task.state), (task.retry?.dueAt ?? .distantPast) <= now,
                      (try? dependenciesReady(task)) == true, !(try pendingPlan(task.id)), !(try openQuestions(task.id)) else { continue }
                do { try project.settings.validate(); clearBackgroundIssue("project-\(project.id)") }
                catch { reportBackgroundIssue(error.localizedDescription, id: "project-\(project.id)", projectID: project.id); continue }
                occupied += 1
                workers[task.id] = Task { await run(task.id) }
            }
            clearBackgroundIssue("scheduler")
        } catch { reportBackgroundIssue(error.localizedDescription, id: "scheduler") }
    }
    private func dependenciesReady(_ task: WorkTask) throws -> Bool {
        for id in Set(task.dependsOn + (task.stackOn.map { [$0] } ?? [])) {
            guard let dependency = try? store.get(WorkTask.self, id) else { return false }
            guard dependency.projectId == task.projectId else { return false }
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
    private func planApproved(_ task: WorkTask, project: Project) throws -> Bool {
        if !(task.askBeforeBuild ?? project.settings.askBeforeBuild) { return true }
        return try store.all(Approval.self).contains { $0.taskId == task.id && $0.kind == "plan" && $0.status == "approved" }
    }
    func transition(_ id: UUID, to state: TaskState, merged: Bool = false) throws {
        var task = try store.get(WorkTask.self, id)
        let project = try store.get(Project.self, task.projectId)
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
    func editTask(_ id: UUID, title: String, description: String, proofRequirement: ProofRequirement) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoreError.invalid("A task title cannot be empty.") }
        guard editingTasks.insert(id).inserted else { throw CoreError.invalid("This task is already being edited.") }
        defer { editingTasks.remove(id) }
        titleJobs[id]?.cancel()
        var task = try store.get(WorkTask.self, id)
        let scopeChanged = task.description != description || task.proofRequirement != proofRequirement
        guard scopeChanged || task.title != title else { return }
        if scopeChanged {
            guard !task.state.terminal, task.state != .inPR, !openingPRs.contains(id) else {
                throw CoreError.invalid("Only the title can be edited after a pull request is opening or the task is finished.")
            }
            await stopPreview(id)
            if task.worktreePath != nil || workers[id] != nil {
                task.paused = true; try store.save(task)
                if let worker = workers[id] {
                    let client = clients[id]
                    let session = try store.session(for: id)
                    if let client, let thread = session.codexThreadId, let turn = session.currentTurn {
                        await client.interrupt(thread: thread, turn: turn)
                    }
                    worker.cancel(); await client?.stop(); await worker.value
                }
                task = try store.get(WorkTask.self, id)
                // Replan atomically below, only after the old worker can no longer publish proof.
                task.state = .todo
                task.paused = true
            }
            task.retry = nil
        }
        task.title = title; task.description = description; task.proofRequirement = proofRequirement; task.updatedAt = Date()
        let edited = task
        try await store.db.write { db in
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
                let body = scopeChanged ? "Task brief or proof updated. Previous proof and plans are superseded." : "Task title updated."
                try Message(sessionId: session.id, role: "system", kind: "event", body: body).insert(db)
            }
        }
    }
    func answer(_ id: UUID, text: String, useSuggested: Bool = false, files: [URL] = []) async throws {
        var question = try store.get(Question.self, id)
        guard question.answer == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("Question is answered or answer is empty") }
        guard question.allowsFreeText || question.options.contains(text) else { throw CoreError.invalid("Choose an offered answer") }
        if useSuggested, question.suggestedAnswer != text { throw CoreError.invalid("The suggested answer changed. Review it again.") }
        if !files.isEmpty {
            let task = try store.get(WorkTask.self, question.taskId)
            let session = try store.session(for: task.id)
            let attachments = try store.saveChatMessage(Message(sessionId: session.id, role: "user", body: text), files: files, projectID: task.projectId, ownerID: task.id)
            if let client = clients[task.id], let thread = session.codexThreadId, let turn = session.currentTurn {
                _ = try await client.request("turn/steer", ["threadId": .string(thread), "expectedTurnId": .string(turn), "input": .chatInput("Reference files for my answer: " + text, attachments: attachments)])
            }
        }
        question.answer = text; question.answeredAt = Date(); question.answeredBy = useSuggested ? "agentDefault" : "user"; try store.save(question)
        let task = try store.get(WorkTask.self, question.taskId)
        if try task.state == .needsClarification && !openQuestions(task.id) {
            let project = try store.get(Project.self, task.projectId)
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
            _ = try await GitHub(runner: runner, root: store.root).verifiedOpenPR(task: current, project: store.get(Project.self, current.projectId))
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
            task.state = .building; task.retry = nil; task.updatedAt = Date()
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
        let attachments = try store.saveChatMessage(Message(sessionId: session.id, role: "user", body: text), files: files, projectID: store.get(WorkTask.self, id).projectId, ownerID: id)
        if let client = clients[id], let thread = session.codexThreadId, let turn = session.currentTurn {
            _ = try await client.request("turn/steer", ["threadId": .string(thread), "expectedTurnId": .string(turn), "input": .chatInput(text, attachments: attachments)])
            return .sent
        }
        return .saved
    }
    func openPullRequest(_ id: UUID) async throws {
        guard !editingTasks.contains(id) else { throw CoreError.invalid("Wait for the task edit to finish.") }
        let task = try store.get(WorkTask.self, id)
        guard openingPRs.insert(id).inserted else { throw CoreError.invalid("Pull request is already opening") }
        defer { openingPRs.remove(id) }
        guard task.state == .humanReview, !task.paused else { throw CoreError.invalid("Task is not ready for a PR") }
        guard let proof = try store.all(Proof.self).first(where: { $0.taskId == id && $0.complete }) else { throw CoreError.invalid("Proof is incomplete") }
        guard let cwd = task.worktreePath else { throw CoreError.invalid("The worktree is unavailable.") }
        await stopPreview(id)
        let head = try await runner.run("git", ["rev-parse", "HEAD"], cwd: cwd).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = try await runner.run("git", ["status", "--porcelain"], cwd: cwd).output.isEmpty
        guard clean, proof.commitSHA == head else { throw CoreError.invalid("The worktree changed since proof was recorded. Ask the agent in chat for fresh proof before opening a pull request.") }
        let project = try store.get(Project.self, task.projectId)
        guard project.host != .local else { throw CoreError.invalid("This project is local. Publishing and pull requests require a hosting service.") }
        var base = project.defaultBranch
        if let parentId = task.stackOn {
            let parent = try store.get(WorkTask.self, parentId)
            if parent.state != .done {
                guard let branch = parent.branchName, parent.pr != nil else { throw CoreError.invalid("Stack base has no pull request") }
                base = branch
            }
        }
        let pr = try await GitHub(runner: runner, root: store.root).open(task: task, project: project, summary: proof.summary, base: base)
        clearBackgroundIssue("pr-\(id)")
        var current = try store.get(WorkTask.self, id)
        current.pr = pr; try store.save(current)
        try transition(id, to: .inPR)
    }
    func pollPR(_ id: UUID) async {
        guard !editingTasks.contains(id), !openingPRs.contains(id), polling.insert(id).inserted else { return }
        defer { polling.remove(id) }
        do {
            let task = try store.get(WorkTask.self, id)
            let project = try store.get(Project.self, task.projectId)
            if task.state == .inPR, try await GitHub(runner: runner, root: store.root).merged(task: task, project: project) {
                guard !editingTasks.contains(id), try store.get(WorkTask.self, id).state == .inPR else { return }
                try transition(id, to: .done, merged: true)
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
        let project = try store.get(Project.self, task.projectId)
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
        let chatPath = chatWorkspace(project).path
        if FileManager.default.fileExists(atPath: chatPath) {
            try Workspace(store: store, runner: runner).ensureOwned(chatPath)
            _ = try await runner.run("git", ["worktree", "remove", chatPath], cwd: project.repoPath)
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
        let client = CodexClient()
        clients[id] = client
        do {
            let task = try store.get(WorkTask.self, id)
            try requireRunnable(task)
            var p = try store.get(Project.self, task.projectId); project = p
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
            availableModels = try await client.models()
            if let thread = session.codexThreadId {
                _ = try await client.request("thread/resume", ["threadId": .string(thread), "cwd": .string(cwd!)])
            } else {
                let selection = try modelSelection(ownerID: id, defaultModel: p.settings.model, defaultEffort: p.settings.effort)
                let started = try await client.request("thread/start", [
                    "cwd": .string(cwd!), "sandbox": .string("workspace-write"), "approvalPolicy": .string("never"),
                    "developerInstructions": .string("You are a Build Mate task agent. Always submit_plan before editing; ask blocking questions when unclear; call request_review after committing the implementation. Do not push, open, or merge pull requests. Only edit this worktree. Treat the current instructions in each turn as authoritative task guidance."),
                    "dynamicTools": CodexClient.tools, "model": .string(selection.model)
                ])
                guard let thread = started["thread"]["id"].string else { throw CoreError.invalid("Missing Codex thread ID") }
                session.codexThreadId = thread
            }
            session.status = "running"; try store.save(session)
            if let limits = try? await client.request("account/rateLimits/read", [:]) { receiveUsage(limits) }
            var idleResponses = 0
            while true {
                try Task.checkCancellation()
                let current = try store.get(WorkTask.self, id)
                guard [.todo, .building].contains(current.state) else { break }
                try requireRunnable(current)
                p = try store.get(Project.self, current.projectId)
                let input = try prompt(task: current, project: p)
                let selection = try modelSelection(ownerID: id, defaultModel: p.settings.model, defaultEffort: p.settings.effort)
                let writableRoots = try await Workspace(store: store, runner: runner).agentWritableRoots(current, project: p)
                session = try store.session(for: id)
                let response = try await client.request("turn/start", [
                    "threadId": .string(session.codexThreadId!), "cwd": .string(cwd!), "input": .chatInput(input, attachments: try store.taskAttachments(id, sessionID: session.id)),
                    "model": .string(selection.model), "effort": selection.effort.map(JSON.string) ?? .null,
                    "sandboxPolicy": .object(["type": .string("workspaceWrite"), "writableRoots": .array(writableRoots.map(JSON.string)),
                                              "networkAccess": .bool(p.settings.network), "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true)])
                ])
                session.activeModel = selection.model; session.activeEffort = selection.effort
                session.currentTurn = response["turn"]["id"].string; session.turnCount += 1; session.lastEventAt = Date(); try store.save(session)
                let started = Date()
                var waitingDuration: TimeInterval = 0
                var complete = false
                var usedTools = false
                while !complete {
                    try Task.checkCancellation()
                    guard Date().timeIntervalSince(started) - waitingDuration < Double(p.settings.turnTimeoutMs) / 1000 else { throw CoreError.invalid("Codex turn timed out") }
                    guard let event = try await client.nextEvent() else {
                        let last = await client.lastEventAt
                        guard p.settings.stallTimeoutMs <= 0 || Date().timeIntervalSince(last) < Double(p.settings.stallTimeoutMs) / 1000 else { throw CoreError.invalid("Codex stalled") }
                        guard Date().timeIntervalSince(started) - waitingDuration < Double(p.settings.turnTimeoutMs) / 1000 else { throw CoreError.invalid("Codex turn timed out") }
                        continue
                    }
                    let method = event["method"].string ?? ""
                    let params = event["params"]
                    if method == "item/tool/call" || method == "item/tool/requestUserInput" ||
                        ((method == "item/started" || method == "item/completed") &&
                         params["item"]["type"].string.map { !["agentMessage", "userMessage", "reasoning", "plan"].contains($0) } == true) {
                        usedTools = true
                    }
                    session = try store.session(for: id); session.lastEventAt = Date()
                    if method == "thread/tokenUsage/updated" {
                        session.tokensIn = params["tokenUsage"]["total"]["inputTokens"].int ?? session.tokensIn
                        session.tokensOut = params["tokenUsage"]["total"]["outputTokens"].int ?? session.tokensOut
                    }
                    try store.save(session)
                    if method == "account/rateLimits/updated" { receiveUsage(params, replacing: false) }
                    if method == "item/tool/call" || method == "item/tool/requestUserInput" {
                        let before = Date()
                        try await handle(event, taskId: id, client: client)
                        waitingDuration += Date().timeIntervalSince(before)
                        let latest = try store.get(WorkTask.self, id)
                        if latest.state == .humanReview || latest.state == .inPR { complete = true }
                    } else if event["id"] != .null { try await client.reject(event["id"]) }
                    else if method == "item/completed", params["item"]["type"].string == "agentMessage" {
                        try store.save(Message(sessionId: session.id, role: "agent", body: runner.redacted(params["item"]["text"].string ?? "")))
                    } else if method == "turn/completed" {
                        guard params["turn"]["status"].string == "completed" else { throw CoreError.invalid("Codex turn \(params["turn"]["status"].string ?? "failed")") }
                        complete = true
                    }
                }
                let latest = try store.get(WorkTask.self, id)
                if latest.state == .humanReview || latest.state == .inPR { break }
                idleResponses = usedTools ? 0 : idleResponses + 1
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
        await client.stop()
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
        if var session = try? store.session(for: id) { session.status = "idle"; session.currentTurn = nil; try? store.save(session) }
        clients.removeValue(forKey: id); workers.removeValue(forKey: id)
    }

    private func requireRunnable(_ task: WorkTask) throws {
        let project = try store.get(Project.self, task.projectId)
        guard !shuttingDown, !Task.isCancelled, project.runBlockReason == nil, !task.paused, !project.paused, !(try store.settings()).paused,
              !task.state.terminal, try dependenciesReady(task) else { throw CancellationError() }
    }

    private func prompt(task: WorkTask, project: Project) throws -> String {
        let answers = try store.all(Question.self).filter { $0.taskId == task.id && $0.answeredBy != "taskEdit" }.map { "\($0.prompt): \($0.answer ?? "unanswered")" }.joined(separator: "\n")
        let session = try store.session(for: task.id)
        let messages = try store.all(Message.self).filter { $0.sessionId == session.id && $0.role == "user" }.map(\.body).joined(separator: "\n")
        return "Global instructions:\n\(try store.settings().instructions)\nProject instructions (override global):\n\(project.instructions)\nTask #\(task.number): \(task.title)\n\(task.description)\nThis current brief and proof preference supersede earlier versions of this task. Reassess the plan after an edit; use earlier answers only where they still apply.\nAnswers:\n\(answers)\nAdditional user messages (newer requests override earlier choices):\n\(messages)\n\(task.pr.map { "Continue work on existing PR #\($0.number) in this same worktree and branch. Ask a blocking question if the requested changes are unclear. After changes, commit and request fresh review; Build Mate updates the existing PR after review. The summary must describe the full branch change against the PR base, not just the latest feedback. Do not push or create another PR." } ?? "")\nProof preference: \(task.proofRequirement.title). Automatic means choose relevant evidence for this task: checks for functional work and a recording for visual work, respecting explicit user instructions in the brief. Checks only suppresses recordings; Checks + recording requires one. Explain the choice in your plan. Write the review summary as concise, readable Markdown describing the changes, using paragraphs and bullets where useful, never JSON. This summary becomes the PR body: include only what changed and why, with no proof reports, recording details, validation logs, commit hashes or Build Mate branding. Put evidence explanations in rationale and checks instead. At request_review supply summary, needsRecording, rationale, checks [{name, command}], and recordingCommand when needed. At least one relevant check must pass; documentation-only work may use a meaningful content or formatting check. The app independently executes these commands in the worktree. Visual screenshot requirement: \(project.settings.screenshotsForUI && task.proofRequirement != .checksOnly). For visual changes when enabled, supply screenshotsCommand writing before (default/base branch) and after PNGs to $BUILD_MATE_BEFORE_PATH and $BUILD_MATE_AFTER_PATH. All evidence output paths are app-owned. A recording command writes MP4/H.264 to $BUILD_MATE_RECORDING_PATH; do not write proof artifacts into the repository. If your persisted tool schema lacks a report field, encode the complete report as JSON in summary, but keep the inner summary field as readable Markdown.\nState: \(task.state.rawValue). Submit a plan before editing; ask questions if unclear. Commit changes before request_review. The current sandbox permits staging and commits on your task branch, including its Git metadata outside the worktree. Retry earlier Git permission failures with these current permissions; do not change repository configuration, other branches, or the main checkout."
    }
    private func waitForAnswer(_ question: Question) async throws -> String {
        while true {
            try Task.checkCancellation()
            if let answer = try store.get(Question.self, question.id).answer { return answer }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func ask(taskId: UUID, prompt: String, options: [String], allowsFreeText: Bool, blocking: Bool, suggestedAnswer: String? = nil) throws -> Question {
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
    private func handle(_ event: JSON, taskId: UUID, client: CodexClient) async throws {
        let params = event["params"]
        let args = params["arguments"]
        let requestId = event["id"]
        let session = try store.session(for: taskId)
        if event["method"].string == "item/tool/requestUserInput" {
            var questions: [(String, Question)] = []
            for item in params["questions"].array {
                guard let key = item["id"].string, let prompt = item["question"].string else { throw CoreError.invalid("Malformed Codex question") }
                let q = try ask(taskId: taskId, prompt: prompt, options: item["options"].array.compactMap { $0["label"].string }, allowsFreeText: true, blocking: true)
                questions.append((key, q))
            }
            var answers: [String: JSON] = [:]
            for (key, question) in questions { answers[key] = .object(["answers": .array([.string(try await waitForAnswer(question))])]) }
            try await client.respondUserInput(requestId, answers: answers)
            return
        }
        switch params["tool"].string {
        case "ask_question":
            guard let prompt = args["prompt"].string, let blocking = args["blocking"].bool else { try await client.respond(requestId, text: "Invalid question", success: false); return }
            let question = try ask(taskId: taskId, prompt: prompt, options: args["options"].array.compactMap(\.string), allowsFreeText: args["allowsFreeText"].bool ?? true, blocking: blocking, suggestedAnswer: args["suggestedAnswer"].string)
            let answer = blocking ? try await waitForAnswer(question) : "Question recorded; continue without depending on an answer."
            guard try dependenciesReady(store.get(WorkTask.self, taskId)) else { throw CancellationError() }
            try await client.respond(requestId, text: answer)
        case "submit_plan":
            guard let plan = args["plan"].string, !plan.isEmpty else { try await client.respond(requestId, text: "Plan is required", success: false); return }
            let task = try store.get(WorkTask.self, taskId)
            let project = try store.get(Project.self, task.projectId)
            try store.save(Message(sessionId: session.id, role: "agent", kind: "plan", body: plan))
            if !(try planApproved(task, project: project)) {
                let approval = Approval(taskId: taskId, kind: "plan", planText: plan)
                try store.save(approval)
                while try store.get(Approval.self, approval.id).status == "pending" {
                    try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100))
                }
            }
            guard try dependenciesReady(store.get(WorkTask.self, taskId)) else { throw CancellationError() }
            if try store.get(WorkTask.self, taskId).state == .todo { try transition(taskId, to: .building) }
            try await client.respond(requestId, text: "Plan accepted. Build within scope.")
        case "request_review":
            let task = try store.get(WorkTask.self, taskId)
            guard task.state == .building else {
                try await client.respond(requestId, text: "Submit your plan and resolve questions before review.", success: false); return
            }
            let submission: ProofSubmission
            do { submission = try ProofSubmission(args) }
            catch { try await client.respond(requestId, text: error.localizedDescription, success: false); return }
            let project = try store.get(Project.self, task.projectId)
            while proofsRunning >= (try store.settings()).heavyStepsAtOnce {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100))
            }
            proofsRunning += 1
            let proof: Proof
            do { proof = try await ProofRunner(store: store, runner: runner).run(task: task, project: project, submission: submission) }
            catch { proofsRunning -= 1; throw error }
            proofsRunning -= 1
            if proof.complete {
                try store.save(Message(sessionId: session.id, role: "system", kind: "event", body: "Proof passed. Ready for review."))
                try transition(taskId, to: .humanReview)
                try await client.respond(requestId, text: "Proof passed. Waiting for human review. Stop now.")
                if !project.settings.askBeforeOpenPR && project.host != .local { try await openPullRequest(taskId) }
            } else {
                let reason = proof.checks.isEmpty ? "Provide at least one relevant executable check." : proof.recordingRequired && proof.recordingPath == nil ? "Provide a playable visual recording using recordingCommand and $BUILD_MATE_RECORDING_PATH." : "Fix the failing checks, provide required before/after screenshots for visual changes, and commit all implementation changes."
                try store.save(Message(sessionId: session.id, role: "system", kind: "proof", body: "Required proof failed. " + reason))
                let messages = try store.all(Message.self).filter { $0.sessionId == session.id }.sorted { $0.createdAt < $1.createdAt }
                let since = messages.last { $0.body == "Proof passed. Ready for review." || $0.body == "Work resumed by you." }?.createdAt ?? .distantPast
                let failures = messages.filter { $0.kind == "proof" && $0.createdAt > since }.count
                if failures >= 3 {
                    var paused = try store.get(WorkTask.self, taskId); paused.paused = true
                    paused.retry = Retry(attempt: 0, dueAt: Date(), error: "Proof failed three times. Review the check logs, then resume when ready.")
                    try store.save(paused)
                }
                try await client.respond(requestId, text: "Required proof failed. " + reason + " Review check logs under app storage; fix and request review again.", success: false)
                if failures >= 3 { throw CancellationError() }
            }
        case "note":
            guard let text = args["text"].string else { try await client.respond(requestId, text: "Text required", success: false); return }
            try store.save(Message(sessionId: session.id, role: "agent", body: runner.redacted(text)))
            try await client.respond(requestId, text: "Recorded")
        default: try await client.respond(requestId, text: "Tool unavailable for this task", success: false)
        }
    }
}
