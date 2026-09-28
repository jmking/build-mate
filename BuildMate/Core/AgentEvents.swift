import Foundation

extension Orchestrator {
    /// Shared transcript persistence for task and project conversations. Transport parsing stays in the runner.
    func consumeAgentEvent(_ event: AgentEvent, session: Session, client: any AgentRunner,
                           streaming: inout [String: UUID], includeCommands: Bool) async throws -> (handled: Bool, progress: Bool) {
        if case .permission(let request) = event.kind {
            try await receiveAgentApproval(request, event: event, session: session)
            return (true, false)
        }
        if case .permissionResolved(let requestID) = event.kind {
            for (id, approval) in agentApprovals where approval.sessionID == session.id && approval.threadID == event.sessionID && approval.request.id == requestID {
                try finishAgentApproval(id, status: "resolved")
            }
            return (true, false)
        }
        if case .turnCompleted = event.kind {
            for (id, approval) in agentApprovals where approval.sessionID == session.id && approval.threadID == event.sessionID && approval.turnID == event.turnID {
                try finishAgentApproval(id)
            }
        }
        if try await routeSubagentEvent(event, session: session, client: client) {
            if case .activity(let kind, _, _) = event.kind {
                let knownChild = try subagents(session.id).contains { $0.threadId == event.sessionID }
                return (true, kind != .other && knownChild)
            }
            return (true, false)
        }
        switch event.kind {
        case .request, .turnCompleted: return (false, false)
        case .message(let id, let text, let complete):
            guard complete || (id != nil && text != nil) else { return (true, false) }
            var message = try id.flatMap { streaming[$0] }.map { try store.get(Message.self, $0) } ?? Message(sessionId: session.id, role: "agent", body: "")
            message.body = runner.redacted(complete ? (text ?? message.body) : message.body + (text ?? ""))
            message.payload = .object(["streaming": .bool(!complete)])
            if let id { streaming[id] = message.id }; try store.save(message)
        case .activity(let kind, let command, let output):
            if includeCommands && kind == .command {
                try store.save(Message(sessionId: session.id, role: "agent", kind: "activity", body: runner.redacted(command ?? "Inspected project"), payload: .object(["output": .string(runner.redacted(output ?? ""))])))
            }
            return (true, kind != .other)
        case .image:
            try consumeGeneratedImage(event, session: session); return (true, true)
        case .tokens(let input, let output):
            var latest = try store.session(for: session.ownerId, ownerType: session.ownerType)
            latest.tokensIn = input ?? latest.tokensIn; latest.tokensOut = output ?? latest.tokensOut; try store.save(latest)
        case .usage(let update): receiveUsage(update, provider: session.provider)
        case .diagnostic(let text): try store.save(Message(sessionId: session.id, role: "system", kind: "error", body: text))
        case .childActivity(_, _, _, let started): return (true, started)
        default: break
        }
        return (true, false)
    }
}
