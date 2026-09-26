import Foundation
import GRDB

actor Orchestrator {
    let store: Store
    let runner: ProcessRunner
    private var loop: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: CodexClient] = [:]
    private var polling: Set<UUID> = []
    private var lastPoll: [UUID: Date] = [:]
    private var heavySteps = 0
    private var openingPRs: Set<UUID> = []
    private var ticking = false
    private var shuttingDown = false
    private(set) var lastError: String?
    private(set) var rateLimits: JSON = .null

    init(store: Store, runner: ProcessRunner = ProcessRunner()) {
        self.store = store; self.runner = runner
    }
    func start() async {
        guard loop == nil else { return }
        shuttingDown = false
        do { try recover() } catch { lastError = error.localizedDescription; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func recover() throws {
        for var attempt in try store.all(RunAttempt.self) where attempt.status == "running" {
            attempt.status = "failed"; attempt.error = "App stopped during attempt; resuming durable thread"; attempt.endedAt = Date()
            try store.save(attempt)
        }
        for var session in try store.all(Session.self) where session.status == "running" {
            session.status = "idle"; session.currentTurn = nil; try store.save(session)
        }
    }
    func shutdown() async {
        shuttingDown = true
        loop?.cancel(); loop = nil
        let pending = Array(workers.values)
        for worker in pending { worker.cancel() }
        for client in clients.values { await client.stop() }
        for worker in pending { await worker.value }
    }
    func tick(now: Date = Date()) async {
        guard !ticking, !shuttingDown else { return }
        ticking = true; defer { ticking = false }
        do {
            let initialSettings = try store.settings()
            let initialTasks = try store.all(WorkTask.self)
            let initialProjects = Dictionary(uniqueKeysWithValues: try store.all(Project.self).map { ($0.id, $0) })
            await withTaskGroup(of: Void.self) { group in
                for task in initialTasks {
                    guard let worker = workers[task.id], let project = initialProjects[task.projectId] else { continue }
                    let unroutable = (try? dependenciesReady(task)) != true
                    if initialSettings.paused || project.paused || task.paused || task.state == .backlog || task.state.terminal || unroutable {
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
            for task in tasks where task.state == .inPR && !polling.contains(task.id) && now.timeIntervalSince(lastPoll[task.id] ?? .distantPast) >= 60 {
                polling.insert(task.id); lastPoll[task.id] = now
                Task { await pollPR(task.id) }
            }
            guard !settings.paused else { return }
            guard settings.agentsAtOnce > 0, settings.heavyStepsAtOnce > 0 else { throw CoreError.invalid("Concurrency limits must be positive") }
            // A waiting worker still owns a process and a slot. Answering cannot overbook the limit.
            var occupied = workers.count
            for task in tasks.sorted(by: { $0.rank == $1.rank ? $0.createdAt < $1.createdAt : $0.rank > $1.rank }) {
                guard occupied < settings.agentsAtOnce else { break }
                guard workers[task.id] == nil, let project = projects[task.projectId], !project.paused, !task.paused, project.runBlockReason == nil,
                      [.todo, .building].contains(task.state), (task.retry?.dueAt ?? .distantPast) <= now,
                      (try? dependenciesReady(task)) == true, !(try pendingPlan(task.id)), !(try openQuestions(task.id)) else { continue }
                do { try project.settings.validate() }
                catch { lastError = error.localizedDescription; continue }
                occupied += 1
                workers[task.id] = Task { await run(task.id) }
            }
        } catch { lastError = runner.redacted(error.localizedDescription) }
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
        var task = try store.get(WorkTask.self, id); task.paused = paused; try store.save(task)
        await tick()
    }
    func answer(_ id: UUID, text: String) async throws {
        var question = try store.get(Question.self, id)
        guard question.answer == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("Question is answered or answer is empty") }
        guard question.allowsFreeText || question.options.contains(text) else { throw CoreError.invalid("Choose an offered answer") }
        question.answer = text; question.answeredAt = Date(); question.answeredBy = "user"; try store.save(question)
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
    @discardableResult
    func steer(_ id: UUID, text: String) async throws -> MessageDelivery {
        let session = try store.session(for: id)
        try store.save(Message(sessionId: session.id, role: "user", body: text))
        if let client = clients[id], let thread = session.codexThreadId, let turn = session.currentTurn {
            _ = try await client.request("turn/steer", ["threadId": .string(thread), "expectedTurnId": .string(turn), "input": .textInput(text)])
            return .sent
        }
        return .saved
    }
    func openPullRequest(_ id: UUID) async throws {
        let task = try store.get(WorkTask.self, id)
        guard openingPRs.insert(id).inserted else { throw CoreError.invalid("Pull request is already opening") }
        defer { openingPRs.remove(id) }
        guard task.state == .humanReview, !task.paused else { throw CoreError.invalid("Task is not ready for a PR") }
        guard let proof = try store.all(Proof.self).first(where: { $0.taskId == id && $0.complete }) else { throw CoreError.invalid("Proof is incomplete") }
        let project = try store.get(Project.self, task.projectId)
        var base = project.defaultBranch
        if let parentId = task.stackOn {
            let parent = try store.get(WorkTask.self, parentId)
            if parent.state != .done {
                guard let branch = parent.branchName, parent.pr != nil else { throw CoreError.invalid("Stack base has no pull request") }
                base = branch
            }
        }
        let pr = try await GitHub(runner: runner, root: store.root).open(task: task, project: project, summary: proof.summary, base: base)
        var current = try store.get(WorkTask.self, id)
        current.pr = pr; try store.save(current)
        try transition(id, to: .inPR)
    }
    func pollPR(_ id: UUID) async {
        defer { polling.remove(id) }
        do {
            let task = try store.get(WorkTask.self, id)
            let project = try store.get(Project.self, task.projectId)
            if try await GitHub(runner: runner, root: store.root).merged(task: task, project: project) {
                try transition(id, to: .done, merged: true)
            }
        } catch { lastError = runner.redacted(error.localizedDescription) }
    }
    func deleteTask(_ id: UUID) async throws {
        guard workers[id] == nil else { throw CoreError.invalid("Pause the task before deleting it") }
        let task = try store.get(WorkTask.self, id)
        let project = try store.get(Project.self, task.projectId)
        try await Workspace(store: store, runner: runner).remove(task, project: project)
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM attachment WHERE ownerType = 'message' AND ownerId IN (SELECT message.id FROM message JOIN session ON session.id = message.sessionId WHERE session.ownerType = 'task' AND session.ownerId = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM session WHERE ownerType = 'task' AND ownerId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM attachment WHERE ownerType = 'task' AND ownerId = ?", arguments: [id])
            _ = try WorkTask.deleteOne(db, key: id)
        }
        let logs = store.root.appending(path: "logs/\(id)")
        if FileManager.default.fileExists(atPath: logs.path) { try FileManager.default.removeItem(at: logs) }
        let media = store.root.appending(path: "projects/\(project.id)/media/\(id)")
        if FileManager.default.fileExists(atPath: media.path) { try FileManager.default.removeItem(at: media) }
    }
    func deleteProject(_ id: UUID) async throws {
        let tasks = try store.all(WorkTask.self).filter { $0.projectId == id }
        guard tasks.allSatisfy({ workers[$0.id] == nil }) else { throw CoreError.invalid("Pause the project before deleting it") }
        for task in tasks { try await deleteTask(task.id) }
        try await store.db.write { db in
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
            let p = try store.get(Project.self, task.projectId); project = p
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
            let instructions = try prompt(task: prepared, project: p)
            if let thread = session.codexThreadId {
                _ = try await client.request("thread/resume", ["threadId": .string(thread), "cwd": .string(cwd!)])
            } else {
                var model = p.settings.model
                if model == nil {
                    let models = try await client.request("model/list", [:])["data"].array
                    model = models.first(where: { $0["isDefault"].bool == true })?["id"].string ?? models.first?["id"].string
                }
                guard let model else { throw CoreError.invalid("No Codex model available") }
                let started = try await client.request("thread/start", [
                    "cwd": .string(cwd!), "sandbox": .string("workspace-write"), "approvalPolicy": .string("never"),
                    "developerInstructions": .string("You are a Build Mate task agent. Always submit_plan before editing; ask blocking questions when unclear; call request_review after committing the implementation. Do not push, open, or merge pull requests. Only edit this worktree. Treat the current instructions in each turn as authoritative task guidance."),
                    "dynamicTools": CodexClient.tools, "model": .string(model)
                ])
                guard let thread = started["thread"]["id"].string else { throw CoreError.invalid("Missing Codex thread ID") }
                session.codexThreadId = thread
            }
            session.status = "running"; try store.save(session)
            if let limits = try? await client.request("account/rateLimits/read", [:]) { rateLimits = limits }
            var input = instructions
            while true {
                try Task.checkCancellation()
                let current = try store.get(WorkTask.self, id)
                guard [.todo, .building].contains(current.state) else { break }
                try requireRunnable(current)
                try Workspace(store: store, runner: runner).ensureOwned(cwd!)
                session = try store.session(for: id)
                if session.turnCount >= p.settings.maxTurnsPerTask {
                    var paused = current; paused.paused = true; try store.save(paused)
                    throw CoreError.invalid("Turn limit reached; review and resume with an increased limit")
                }
                let response = try await client.request("turn/start", [
                    "threadId": .string(session.codexThreadId!), "cwd": .string(cwd!), "input": .textInput(input),
                    "effort": p.settings.effort.map(JSON.string) ?? .null,
                    "sandboxPolicy": .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(cwd!)]),
                                              "networkAccess": .bool(p.settings.network), "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true)])
                ])
                session.currentTurn = response["turn"]["id"].string; session.turnCount += 1; session.lastEventAt = Date(); try store.save(session)
                let started = Date()
                var waitingDuration: TimeInterval = 0
                var complete = false
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
                    session = try store.session(for: id); session.lastEventAt = Date()
                    if method == "thread/tokenUsage/updated" {
                        session.tokensIn = params["tokenUsage"]["total"]["inputTokens"].int ?? session.tokensIn
                        session.tokensOut = params["tokenUsage"]["total"]["outputTokens"].int ?? session.tokensOut
                    }
                    try store.save(session)
                    if method == "account/rateLimits/updated" { rateLimits = params }
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
                let latestProject = try store.get(Project.self, latest.projectId)
                input = try prompt(task: latest, project: latestProject) + "\nContinue the task; request review when ready."
                try await Task.sleep(for: .seconds(1))
            }
            attempt?.status = "succeeded"
            var finishedTask = try store.get(WorkTask.self, id); finishedTask.retry = nil; try store.save(finishedTask)
        } catch is CancellationError {
            attempt?.status = "canceled"
        } catch {
            let message = runner.redacted(error.localizedDescription)
            attempt?.status = message.contains("stalled") ? "stalled" : message.contains("timed out") ? "timedOut" : "failed"
            attempt?.error = message
            do {
                var task = try store.get(WorkTask.self, id)
                if !task.state.terminal && !task.paused && task.state != .backlog {
                    let number = (task.retry?.attempt ?? 0) + 1
                    let delay = min(10 * pow(2, Double(min(number - 1, 20))), Double(project?.settings.retryBackoffMaxMs ?? 300_000) / 1000)
                    task.retry = Retry(attempt: number, dueAt: Date().addingTimeInterval(delay), error: message)
                    try store.save(task)
                }
            } catch { lastError = error.localizedDescription }
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
            if let result { lastError = "After run: " + result }
        }
        if var attempt { attempt.endedAt = Date(); try? store.save(attempt) }
        if var session = try? store.session(for: id) { session.status = "idle"; session.currentTurn = nil; try? store.save(session) }
        clients.removeValue(forKey: id); workers.removeValue(forKey: id)
    }

    private func requireRunnable(_ task: WorkTask) throws {
        let project = try store.get(Project.self, task.projectId)
        guard !shuttingDown, project.runBlockReason == nil, !task.paused, !project.paused, !(try store.settings()).paused,
              !task.state.terminal, task.state != .backlog, try dependenciesReady(task) else { throw CancellationError() }
    }

    private func prompt(task: WorkTask, project: Project) throws -> String {
        let answers = try store.all(Question.self).filter { $0.taskId == task.id }.map { "\($0.prompt): \($0.answer ?? "unanswered")" }.joined(separator: "\n")
        let session = try store.session(for: task.id)
        let messages = try store.all(Message.self).filter { $0.sessionId == session.id && $0.role == "user" }.map(\.body).joined(separator: "\n")
        return "Global instructions:\n\(try store.settings().instructions)\nProject instructions (override global):\n\(project.instructions)\nTask #\(task.number): \(task.title)\n\(task.description)\nAnswers:\n\(answers)\nAdditional user messages:\n\(messages)\nProof preference: \(task.proofRequirement.title). Automatic means choose relevant evidence for this task: checks for functional work and a recording for visual work, respecting explicit user instructions in the brief. Checks only suppresses recordings; Checks + recording requires one. Explain the choice in your plan. At request_review supply summary, needsRecording, rationale, checks [{name, command}], and recordingCommand when needed. At least one relevant check must pass; documentation-only work may use a meaningful content or formatting check. The app independently executes these commands in the worktree. A recording command writes MP4 to $BUILD_MATE_RECORDING_PATH; do not write proof artifacts into the repository. If your persisted tool schema only accepts summary, encode the complete report as JSON in summary.\nState: \(task.state.rawValue). Submit a plan before editing; ask questions if unclear. Commit changes before request_review."
    }
    private func waitForAnswer(_ question: Question) async throws -> String {
        while true {
            try Task.checkCancellation()
            if let answer = try store.get(Question.self, question.id).answer { return answer }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func ask(taskId: UUID, prompt: String, options: [String], allowsFreeText: Bool, blocking: Bool) throws -> Question {
        guard !prompt.isEmpty else { throw CoreError.invalid("Question needs a prompt") }
        let session = try store.session(for: taskId)
        let message = Message(sessionId: session.id, role: "agent", kind: "question", body: prompt)
        let question = Question(taskId: taskId, messageId: message.id, prompt: prompt, options: options, allowsFreeText: allowsFreeText, blocking: blocking)
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
            let question = try ask(taskId: taskId, prompt: prompt, options: args["options"].array.compactMap(\.string), allowsFreeText: args["allowsFreeText"].bool ?? true, blocking: blocking)
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
            while heavySteps >= (try store.settings()).heavyStepsAtOnce {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100))
            }
            heavySteps += 1
            let proof: Proof
            do { proof = try await ProofRunner(store: store, runner: runner).run(task: task, project: project, submission: submission) }
            catch { heavySteps -= 1; throw error }
            heavySteps -= 1
            if proof.complete {
                try transition(taskId, to: .humanReview)
                try await client.respond(requestId, text: "Proof passed. Waiting for human review. Stop now.")
                if !project.settings.askBeforeOpenPR { try await openPullRequest(taskId) }
            } else {
                let reason = proof.checks.isEmpty ? "Provide at least one relevant executable check." : proof.recordingRequired && proof.recordingPath == nil ? "Provide a playable visual recording using recordingCommand and $BUILD_MATE_RECORDING_PATH." : "Fix the failing checks and commit all implementation changes."
                try store.save(Message(sessionId: session.id, role: "system", kind: "proof", body: "Required proof failed. " + reason))
                let failures = try store.all(Message.self).filter { $0.sessionId == session.id && $0.kind == "proof" }.count
                if failures >= 3 { var paused = task; paused.paused = true; try store.save(paused) }
                try await client.respond(requestId, text: "Required proof failed. " + reason + " Review check logs under app storage; fix and request review again.", success: false)
            }
        case "note":
            guard let text = args["text"].string else { try await client.respond(requestId, text: "Text required", success: false); return }
            try store.save(Message(sessionId: session.id, role: "agent", body: runner.redacted(text)))
            try await client.respond(requestId, text: "Recorded")
        default: try await client.respond(requestId, text: "Tool unavailable for this task", success: false)
        }
    }
}
