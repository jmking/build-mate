import Foundation
import GRDB

extension Orchestrator {
    static let delegationConfiguration: JSON = .object(["agents.enabled": .bool(true)])
    static let delegationInstructions = """
    Delegate suitable independent work to Codex subagents when it helps; use your judgment and keep simple work local. The parent remains responsible for the complete result: give each child a focused scope, coordinate shared files, review its findings and integrate and validate its work. Only the parent may call Build Mate's dynamic tools, ask the user questions, submit plans, create or refine tasks, commit changes or request review. If you are a delegated child, work only within your assigned scope and report results or blockers to your parent; do not call Build Mate tools or commit. Obtain any required plan approval before delegating edits. Wait for or close all active children before committing, requesting review or finishing your response. Do not delegate authority to change task state or expand sandbox permissions.
    """

    func subagents(_ sessionID: UUID) throws -> [Subagent] {
        try store.db.read { try Subagent.filter(Column("sessionId") == sessionID).fetchAll($0) }
    }

    func interruptSubagents(_ sessionID: UUID) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE subagent SET status = 'interrupted', currentTurn = NULL, updatedAt = ? WHERE sessionId = ? AND status IN ('pendingInit', 'running')", arguments: [Date(), sessionID])
        }
    }

    /// Child events are kept out of the parent's transcript, usage and lifecycle.
    /// Returns true for an event that must not reach the parent event handler.
    func routeSubagentEvent(_ event: JSON, session: Session, client: CodexClient) async throws -> Bool {
        guard let root = session.codexThreadId else { return false }
        let method = event["method"].string ?? "", params = event["params"]
        var agents = try subagents(session.id)
        func known(_ id: String) -> Bool { id == root || agents.contains { $0.threadId == id } }
        let thread = params["threadId"].string ?? params["thread"]["id"].string
        let turn = params["turnId"].string ?? params["turn"]["id"].string
        // Filter old root turns before they can also rewrite delegated activity.
        if thread == root, let turn, let current = session.currentTurn, turn != current {
            if event["id"] != .null { try await client.reject(event["id"]) }
            return true
        }
        if method == "turn/completed", thread == nil { return true }
        var discovered: [String] = []

        func save(_ agent: Subagent) throws {
            var agent = agent; agent.updatedAt = Date()
            try store.save(agent)
            agents.removeAll { $0.threadId == agent.threadId }; agents.append(agent)
        }
        func child(_ id: String, parent: String) -> Subagent {
            if let agent = agents.first(where: { $0.threadId == id }) { return agent }
            discovered.append(id)
            return Subagent(sessionId: session.id, threadId: id, parentThreadId: parent)
        }

        if method == "thread/started", let id = thread, id != root,
           let parent = params["thread"]["parentThreadId"].string, known(parent) {
            var agent = child(id, parent: parent)
            applySubagentMetadata(params["thread"], to: &agent)
            try save(agent)
        }
        if method == "item/started" || method == "item/completed" {
            let item = params["item"]
            if item["type"].string == "subAgentActivity", let parent = thread, known(parent),
               let id = item["agentThreadId"].string, id != root {
                var agent = child(id, parent: parent)
                if let path = item["agentPath"].string, let name = path.split(separator: "/").last {
                    agent.name = runner.redacted(String(name).replacingOccurrences(of: "_", with: " "))
                }
                switch item["kind"].string {
                case "interacted" where method == "item/started": agent.status = "pendingInit"
                case "interrupted" where agent.currentTurn == nil: agent.status = "interrupted"
                case "completed" where agent.currentTurn == nil: agent.status = "completed"
                default: break
                }
                try save(agent)
            } else if item["type"].string == "collabAgentToolCall",
                      let parent = item["senderThreadId"].string, known(parent) {
                var ids = item["receiverThreadIds"].array.compactMap(\.string)
                if case .object(let states) = item["agentsStates"] { ids += states.keys }
                for id in Set(ids) where id != root {
                    // An agent can message its parent; only spawn or known child IDs establish ownership.
                    guard agents.contains(where: { $0.threadId == id }) || item["tool"].string == "spawnAgent" else { continue }
                    var agent = child(id, parent: parent)
                    if let prompt = item["prompt"].string { agent.prompt = runner.redacted(prompt) }
                    if let model = item["model"].string { agent.model = model }
                    if let effort = item["reasoningEffort"].string { agent.effort = effort }
                    if let status = item["agentsStates"][id]["status"].string { agent.status = status }
                    if let result = item["agentsStates"][id]["message"].string { agent.result = runner.redacted(result) }
                    if !agent.isActive { agent.currentTurn = nil }
                    try save(agent)
                }
            }
        }
        // Native children are automatically subscribed. Metadata reads are local, read-only,
        // and do not resume a child or create another Build Mate task.
        for id in Set(discovered) {
            if let value = try? await client.request("thread/read", ["threadId": .string(id), "includeTurns": .bool(true)], timeout: 2),
               var agent = agents.first(where: { $0.threadId == id }) {
                applySubagentMetadata(value["thread"], to: &agent)
                try save(agent)
            }
        }
        try Task.checkCancellation()
        let toolRequest = method == "item/tool/call" || method == "item/tool/requestUserInput"
        if (thread != nil && thread != root) || (toolRequest && thread == nil) {
            if let thread, var agent = agents.first(where: { $0.threadId == thread }) {
                switch method {
                case "turn/started":
                    agent.status = "running"; agent.currentTurn = params["turn"]["id"].string
                case "item/completed":
                    if params["item"]["type"].string == "agentMessage" {
                        agent.result = runner.redacted(params["item"]["text"].string ?? "")
                    }
                case "turn/completed":
                    let turn = params["turn"]
                    if agent.currentTurn == nil || agent.currentTurn == turn["id"].string {
                        agent.status = turn["status"].string == "failed" ? "errored" : (turn["status"].string ?? "interrupted")
                        agent.currentTurn = nil
                    }
                case "thread/status/changed":
                    if params["status"]["type"].string == "active" { agent.status = "running" }
                    if params["status"]["type"].string == "systemError" { agent.status = "errored" }
                case "thread/closed":
                    if agent.isActive { agent.status = "interrupted"; agent.currentTurn = nil }
                default: break
                }
                try save(agent)
            }
            if event["id"] != .null {
                if method == "item/tool/call" {
                    try await client.respond(event["id"], text: "Only the parent agent may use Build Mate tools. Report your findings or question to your parent; it owns task state and user interaction.", success: false)
                } else { try await client.reject(event["id"]) }
            }
            return true
        }
        return false
    }

    private func applySubagentMetadata(_ thread: JSON, to agent: inout Subagent) {
        if let name = thread["name"].string, !name.isEmpty { agent.name = runner.redacted(name) }
        else if agent.name == "Subagent", let name = thread["agentNickname"].string { agent.name = runner.redacted(name) }
        agent.model = thread["model"].string ?? agent.model
        agent.effort = thread["reasoningEffort"].string ?? agent.effort
        if agent.prompt.isEmpty {
            let messages = thread["turns"].array.flatMap { $0["items"].array }.filter { $0["type"].string == "userMessage" }
            let text = messages.last?["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
            agent.prompt = runner.redacted(text ?? thread["preview"].string ?? "")
        }
    }
}
