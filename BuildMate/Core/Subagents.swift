import Foundation
import GRDB

extension Orchestrator {
    static let delegationInstructions = """
    Delegate suitable independent work to native subagents when it helps; use your judgment and keep simple work local. The parent remains responsible for the complete result: give each child a focused scope, coordinate shared files, review its findings and integrate and validate its work. Only the parent may call Build Mate's tools, ask the user questions, submit plans, create or refine tasks, commit changes or request review. If you are a delegated child, work only within your assigned scope and report results or blockers to your parent; do not call Build Mate tools or commit. Obtain any required plan approval before delegating edits. Wait for or close all active children before committing, requesting review or finishing your response. Do not delegate authority to change task state or expand sandbox permissions.
    """

    func subagents(_ sessionID: UUID) throws -> [Subagent] {
        try store.db.read { try Subagent.filter(Column("sessionId") == sessionID).fetchAll($0) }
    }

    func interruptSubagents(_ sessionID: UUID) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE subagent SET status = 'interrupted', currentTurn = NULL, updatedAt = ? WHERE sessionId = ? AND status IN ('pendingInit', 'running')", arguments: [Date(), sessionID])
        }
    }

    /// Child events never enter the parent transcript, token totals or lifecycle tools.
    func routeSubagentEvent(_ event: AgentEvent, session: Session, client: any AgentRunner) async throws -> Bool {
        guard let root = session.providerSessionID else { return false }
        var agents = try subagents(session.id)
        let thread = event.sessionID, turn = event.turnID
        if thread == root, let turn, let current = session.currentTurn, turn != current {
            if case .request(let request) = event.kind { try await request.respond("This turn is no longer active.", success: false) }
            return true
        }
        if case .turnCompleted = event.kind, thread == nil { return true }
        var discovered: [String] = []
        func save(_ agent: Subagent) throws {
            var agent = agent; agent.updatedAt = Date(); try store.save(agent)
            agents.removeAll { $0.threadId == agent.threadId }; agents.append(agent)
        }
        func child(_ id: String, parent: String) -> Subagent {
            if let agent = agents.first(where: { $0.threadId == id }) { return agent }
            discovered.append(id)
            return Subagent(sessionId: session.id, threadId: id, parentThreadId: parent)
        }
        switch event.kind {
        case .children(let children):
            for value in children {
                guard value.id != root, value.allowsDiscovery || agents.contains(where: { $0.threadId == value.id }) else { continue }
                let parentKnown = value.parentID == root || agents.contains { $0.threadId == value.parentID }
                guard parentKnown else { continue }
                var agent = child(value.id, parent: value.parentID)
                applySubagentMetadata(value, to: &agent)
                if let status = value.status { agent.status = status }
                if let result = value.result { agent.result = runner.redacted(result) }
                if !agent.isActive { agent.currentTurn = nil }
                try save(agent)
            }
        case .childActivity(let id, let name, let status, _):
            if let parent = thread, id != root {
                let parentKnown = parent == root || agents.contains { $0.threadId == parent }
                guard parentKnown else { break }
                var agent = child(id, parent: parent)
                if let name { agent.name = runner.redacted(name) }
                if let status, status == "pendingInit" || agent.currentTurn == nil { agent.status = status }
                try save(agent)
            }
        default: break
        }
        for id in Set(discovered) {
            if var agent = agents.first(where: { $0.threadId == id }),
               let details = try? await client.childDetails(id, parent: agent.parentThreadId) {
                applySubagentMetadata(details, to: &agent); try save(agent)
            }
        }
        try Task.checkCancellation()
        let isRequest: Bool = if case .request = event.kind { true } else { false }
        if (thread != nil && thread != root) || (isRequest && thread == nil) {
            if let thread, var agent = agents.first(where: { $0.threadId == thread }) {
                switch event.kind {
                case .turnStarted(let id): agent.status = "running"; agent.currentTurn = id
                case .message(_, let text, let complete): if complete, let text { agent.result = runner.redacted(text) }
                case .turnCompleted(let status):
                    if agent.currentTurn == nil || agent.currentTurn == turn {
                        agent.status = status == "failed" ? "errored" : status; agent.currentTurn = nil
                    }
                case .threadStatus(let status):
                    if status == "active" { agent.status = "running" }
                    if status == "systemError" { agent.status = "errored" }
                case .threadClosed: if agent.isActive { agent.status = "interrupted"; agent.currentTurn = nil }
                default: break
                }
                try save(agent)
            }
            if case .request(let request) = event.kind {
                try await request.respond("Only the parent agent may use Build Mate tools. Report your findings or question to your parent; it owns task state and user interaction.", success: false)
            }
            return true
        }
        return false
    }

    private func applySubagentMetadata(_ details: AgentChild, to agent: inout Subagent) {
        if let name = details.name, !name.isEmpty { agent.name = runner.redacted(name) }
        else if agent.name == "Subagent", let name = details.fallbackName { agent.name = runner.redacted(name) }
        agent.model = details.model ?? agent.model; agent.effort = details.effort ?? agent.effort
        if agent.prompt.isEmpty { agent.prompt = runner.redacted(details.prompt ?? "") }
    }
}
