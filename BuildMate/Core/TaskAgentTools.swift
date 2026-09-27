import Foundation
import GRDB

extension Orchestrator {
    func handleTaskRequest(_ request: AgentRequest, taskId: UUID) async throws -> Bool {
        let args = request.arguments
        let session = try store.session(for: taskId)
        if let requested = request.questions {
            var questions: [(String, Question)] = []
            var answers: [String: String] = [:]
            for item in requested {
                let key = item.id, prompt = item.prompt
                if item.secret {
                    answers[key] = "Secret input is not supported here. Ask the user to authenticate through the tool that owns the credentials; do not ask them to paste secrets into chat."
                    continue
                }
                let q = try ask(taskId: taskId, prompt: prompt, options: item.options, allowsFreeText: item.allowsFreeText, blocking: item.blocking)
                questions.append((key, q))
            }
            for (key, question) in questions {
                let answer = question.blocking ? try await waitForAnswer(question) : "Question recorded. Continue without depending on an answer."
                answers[key] = answer
            }
            try await request.reply(.answers(answers))
            try store.acknowledgeInput(session: session, ids: questions.filter { $0.1.blocking }.map { $0.1.id })
            return questions.contains { $0.1.blocking }
        }
        switch request.name {
        case "ask_question":
            guard let prompt = args["prompt"].string, let blocking = args["blocking"].bool else { try await request.respond("Invalid question", success: false); return false }
            let question = try ask(taskId: taskId, prompt: prompt, options: args["options"].array.compactMap(\.string), allowsFreeText: args["allowsFreeText"].bool ?? true, blocking: blocking, suggestedAnswer: args["suggestedAnswer"].string)
            let answer = blocking ? try await waitForAnswer(question) : "Question recorded; continue without depending on an answer."
            guard try dependenciesReady(store.get(WorkTask.self, taskId)) else { throw CancellationError() }
            try await request.respond(answer)
            if blocking { try store.acknowledgeInput(session: session, ids: [question.id]) }
            return blocking
        case "submit_plan":
            guard let plan = args["plan"].string, !plan.isEmpty else { try await request.respond("Plan is required", success: false); return false }
            let task = try store.get(WorkTask.self, taskId)
            let project = try store.get(Project.self, task.projectId)
            if args["affectedPaths"] != .null {
                var claimed = task; claimed.affectedPaths = try WorkTask.validatedPaths(args["affectedPaths"].array.compactMap(\.string)); try store.save(claimed)
                if scopeIsBusy(claimed) {
                    try await request.respond("Another task currently owns overlapping paths. Your plan is saved; work will resume when that task yields.", success: false)
                    throw CancellationError()
                }
            }
            let previousPlan = try store.all(Message.self).filter { $0.sessionId == session.id && $0.kind == "plan" }.max { $0.createdAt < $1.createdAt }?.body
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
            try await request.respond("Plan accepted. Build within scope.")
            return task.state == .todo || previousPlan != plan
        case "request_review":
            guard try !subagents(session.id).contains(where: \.isActive) else {
                try await request.respond("Wait for or close your active subagents, review their work, and commit the final changes before requesting review.", success: false); return false
            }
            let task = try store.get(WorkTask.self, taskId)
            guard task.state == .building else {
                try await request.respond("Submit your plan and resolve questions before review.", success: false); return false
            }
            let submission: ProofSubmission
            do { submission = try ProofSubmission(args) }
            catch { try await request.respond(error.localizedDescription, success: false); return false }
            let project = try store.get(Project.self, task.projectId)
            while proofsRunning >= Self.computeCapacity(min(2, (try store.settings()).heavyStepsAtOnce)) {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100))
            }
            proofsRunning += 1
            let proof: Proof
            do { proof = try await ProofRunner(store: store, runner: runner).run(task: task, project: project, submission: submission) }
            catch { proofsRunning -= 1; throw error }
            proofsRunning -= 1
            if proof.complete {
                var pending = proof; pending.complete = false; pending.qaToken = UUID().uuidString; try store.save(pending)
                let response: JSON = .object(["proofToken": .string(pending.qaToken!), "inspectedPaths": .array(pending.evidencePaths.map(JSON.string)), "instructions": .string(Self.qaInstructions)])
                try await request.respond(response.text)
            } else {
                let diagnostics = ProofRunner(store: store, runner: runner).failureFeedback(proof)
                let reason = !diagnostics.isEmpty ? diagnostics : proof.checks.isEmpty ? "Provide at least one relevant executable check." : proof.recordingRequired && proof.recordingPath == nil ? "Provide a playable visual recording using recordingCommand and $BUILD_MATE_RECORDING_PATH." : "Fix the failing checks, provide required before/after screenshots for visual changes, and commit all implementation changes."
                try store.save(Message(sessionId: session.id, role: "system", kind: "proof", body: "Required proof failed. " + reason))
                let messages = try store.all(Message.self).filter { $0.sessionId == session.id }.sorted { $0.createdAt < $1.createdAt }
                let since = messages.last { $0.body == "Proof passed. Ready for review." || $0.body == "Work resumed by you." }?.createdAt ?? .distantPast
                let failures = messages.filter { $0.kind == "proof" && $0.createdAt > since }.count
                if failures >= 3 {
                    var paused = try store.get(WorkTask.self, taskId); paused.paused = true
                    paused.retry = Retry(attempt: 0, dueAt: Date(), error: "Proof failed three times. Review the check logs, then resume when ready.")
                    try store.save(paused)
                }
                try await request.respond("Required proof failed. " + reason + " Fix the reported problems and request review again.", success: false)
                if failures >= 3 { throw CancellationError() }
            }
            return true
        case "review_action":
            do { let result = try await reviewAction(taskId, arguments: args); try await request.respond(result); return true }
            catch { try await request.respond(runner.redacted(error.localizedDescription), success: false); return false }
        case "complete_qa":
            do { try await completeQA(taskID: taskId, arguments: args); try await request.respond("QA complete. The delivery workflow will continue or wait for human review. Stop now."); return true }
            catch { try await request.respond(runner.redacted(error.localizedDescription), success: false); return false }
        case "note":
            guard let text = args["text"].string else { try await request.respond("Text required", success: false); return false }
            if text.hasPrefix("BUILD_MATE_PR ") {
                do {
                    let args = try JSONDecoder().decode(JSON.self, from: Data(text.dropFirst("BUILD_MATE_PR ".count).utf8))
                    let result = try await reviewAction(taskId, arguments: args)
                    try await request.respond(result); return true
                } catch { try await request.respond(runner.redacted(error.localizedDescription), success: false); return false }
            }
            if text.hasPrefix("BUILD_MATE_QA ") {
                do {
                    let receipt = try JSONDecoder().decode(JSON.self, from: Data(text.dropFirst("BUILD_MATE_QA ".count).utf8))
                    try await completeQA(taskID: taskId, arguments: receipt)
                    try await request.respond("QA complete. Stop now."); return true
                } catch { try await request.respond(runner.redacted(error.localizedDescription), success: false); return false }
            }
            try store.save(Message(sessionId: session.id, role: "agent", body: runner.redacted(text)))
            try await request.respond("Recorded")
        default: try await request.respond("Tool unavailable for this task", success: false)
        }
        return false
    }
}
