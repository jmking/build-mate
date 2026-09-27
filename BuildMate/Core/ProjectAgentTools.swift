import Foundation
import GRDB

extension Orchestrator {
    func handleProjectRequest(_ request: AgentRequest, projectID: UUID, sessionID: UUID) async throws {
        var answeredIDs: [UUID] = []
        if let requested = request.questions {
            var answers: [String: String] = [:]
            for question in requested {
                let id = question.id, prompt = question.prompt
                if question.secret {
                    answers[id] = "Secret input is not supported here. Ask the user to authenticate through the tool that owns the credentials; do not ask them to paste secrets into chat."
                    continue
                }
                let answer = try await projectQuestion(projectID: projectID, sessionID: sessionID, prompt: prompt,
                                                      options: question.options, allowsFreeText: question.allowsFreeText, blocking: question.blocking)
                answers[id] = answer.answer
                if answer.delivered { answeredIDs.append(answer.id) }
            }
            try await request.reply(.answers(answers))
            try store.acknowledgeInput(session: store.session(for: projectID, ownerType: "project"), ids: answeredIDs)
            return
        }
        do {
            let args = request.arguments
            let result: String
            switch request.name {
            case "project_status": result = try projectStatus(projectID).text
            case "note":
                guard let text = args["text"].string else { throw CoreError.invalid("Text required") }
                try store.save(Message(sessionId: sessionID, role: "agent", body: runner.redacted(text))); result = "Recorded"
            case "ask_question":
                guard let prompt = args["prompt"].string else { throw CoreError.invalid("Prompt required") }
                let answer = try await projectQuestion(projectID: projectID, sessionID: sessionID, prompt: prompt, options: args["options"].array.compactMap(\.string), allowsFreeText: args["allowsFreeText"].bool ?? true)
                result = answer.answer; answeredIDs.append(answer.id)
            case "propose_tasks":
                let proposal = try saveProposal(projectID, sessionID: sessionID, items: proposalItems(args["tasks"]))
                result = "Proposal \(proposal.id). Wait for the user to select tasks or explicitly request creation."
            case "create_tasks":
                let proposal: Proposal
                if let rawID = args["proposalId"].string {
                    guard let id = UUID(uuidString: rawID) else { throw CoreError.invalid("Invalid proposal ID") }
                    proposal = try store.get(Proposal.self, id)
                    guard proposal.projectId == projectID else { throw CoreError.invalid("Proposal belongs to another project") }
                } else { proposal = try saveProposal(projectID, sessionID: sessionID, items: proposalItems(args["tasks"])) }
                let selected = args["selectedIndexes"] == .null ? Set(proposal.tasks.indices) : Set(args["selectedIndexes"].array.compactMap(\.int))
                let tasks = try await acceptProposal(proposal.id, projectID: projectID, selected: selected)
                result = String(decoding: try JSONEncoder().encode(tasks), as: UTF8.self)
            case "reshape_tasks":
                let ids = args["taskIds"].array.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
                let tasks = try await reshapeTasks(projectID: projectID, sourceIDs: ids, items: proposalItems(args["tasks"]), reason: args["reason"].string ?? "")
                result = String(decoding: try JSONEncoder().encode(tasks), as: UTF8.self)
            case "refine_task":
                guard let raw = args["taskId"].string, let id = UUID(uuidString: raw), let description = args["description"].string,
                      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("Task and description required") }
                let task = try store.get(WorkTask.self, id)
                guard task.projectId == projectID else { throw CoreError.invalid("Task belongs to another project.") }
                let references = args["attachmentIds"].array.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
                let updated = try await reviseFromProject(task, title: args["title"].string ?? task.title, description: description, attachmentIDs: references)
                try store.save(Message(sessionId: sessionID, role: "system", kind: "event", body: "Updated \(updated.title)."))
                result = "Task \(updated.id): \(updated.state.rawValue). Explicitly paused: \(updated.paused). Requirements revision \(updated.requirementsRevision)."
            default: throw CoreError.invalid("Tool unavailable for project chat")
            }
            try await request.respond(result)
            try store.acknowledgeInput(session: store.session(for: projectID, ownerType: "project"), ids: answeredIDs)
        } catch is CancellationError { throw CancellationError() }
        catch { try await request.respond(runner.redacted(error.localizedDescription), success: false) }
    }
}
