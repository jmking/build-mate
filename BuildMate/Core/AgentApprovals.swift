import Foundation
import GRDB

struct PendingAgentApproval: Sendable {
    var sessionID: UUID
    var threadID: String
    var turnID: String
    var request: AgentPermissionRequest
}
struct AgentApprovalClock: Sendable {
    var started: SuspendingClock.Instant?
    var elapsed: Duration = .zero
}

extension Message {
    var isPendingAgentApproval: Bool { kind == "agentApproval" && payload["status"].string == "pending" }
}

extension Orchestrator {
    func hasAgentApproval(_ sessionID: UUID) -> Bool {
        agentApprovals.values.contains { $0.sessionID == sessionID }
    }
    func agentApprovalWait(_ sessionID: UUID) -> Duration {
        guard let clock = agentApprovalClocks[sessionID] else { return .zero }
        return clock.elapsed + (clock.started?.duration(to: SuspendingClock.now) ?? .zero)
    }
    private func updateAgentApprovalWait(_ sessionID: UUID) throws {
        var clock = agentApprovalClocks[sessionID] ?? AgentApprovalClock()
        let waiting = hasAgentApproval(sessionID)
        if waiting && clock.started == nil { clock.started = .now }
        if !waiting, let started = clock.started { clock.elapsed += started.duration(to: .now); clock.started = nil }
        agentApprovalClocks[sessionID] = clock
        var session = try store.get(Session.self, sessionID)
        if ["running", "approval"].contains(session.status) { session.status = waiting ? "approval" : "running"; try store.save(session) }
    }

    /// Keep reading the stream while a request is visible, so cancellation and server resolution still work.
    func receiveAgentApproval(_ request: AgentPermissionRequest, event: AgentEvent, session: Session) async throws {
        let session = try store.get(Session.self, session.id)
        guard let thread = event.sessionID, let activeTurn = session.currentTurn else { try await request.reply(false); return }
        let child = try subagents(session.id).first { $0.threadId == thread && $0.isActive }
        let expectedTurn = thread == session.providerSessionID ? activeTurn : child?.currentTurn
        guard let expectedTurn, event.turnID == expectedTurn || (request.allowsMissingTurn && event.turnID == nil && thread == session.providerSessionID) else {
            try await request.reply(false); return
        }
        guard !agentApprovals.values.contains(where: { $0.sessionID == session.id && $0.request.id == request.id }) else { return }
        let message = Message(sessionId: session.id, role: "system", kind: "agentApproval", body: request.title, payload: .object([
            "status": .string("pending"), "reason": .string(runner.redacted(request.reason)),
            "details": .string(runner.redacted(request.details)), "allowLabel": .string(request.allowLabel),
            "url": request.url.map { .string(runner.redacted($0)) } ?? .null,
            "agent": child.map { .string($0.name) } ?? .null
        ]))
        try store.save(message)
        agentApprovals[message.id] = PendingAgentApproval(sessionID: session.id, threadID: thread, turnID: expectedTurn, request: request)
        try updateAgentApprovalWait(session.id)
    }

    func resolveAgentApproval(_ messageID: UUID, allow: Bool) async throws {
        guard let pending = agentApprovals[messageID], try store.get(Message.self, messageID).isPendingAgentApproval,
              !shuttingDown else { throw CoreError.invalid("This approval is no longer active. Ask the agent to retry the action.") }
        let session = try store.get(Session.self, pending.sessionID)
        let task = session.ownerType == "task" ? try store.get(WorkTask.self, session.ownerId) : nil
        let project = try store.get(Project.self, task?.projectId ?? session.ownerId)
        guard try !store.settings().paused, !project.paused, task?.paused != true, !editingTasks.contains(session.ownerId) else {
            throw CoreError.invalid("This conversation is paused or being changed. Resume it before approving an action.")
        }
        let currentTurn = pending.threadID == session.providerSessionID ? session.currentTurn : try subagents(session.id).first { $0.threadId == pending.threadID && $0.isActive }?.currentTurn
        guard currentTurn == pending.turnID else {
            try finishAgentApproval(messageID, status: "expired")
            throw CoreError.invalid("This approval belongs to an earlier run. Ask the agent to retry the action.")
        }
        // Consume the callback before awaiting transport: double clicks cannot grant twice.
        agentApprovals[messageID] = nil
        do {
            try await pending.request.reply(allow)
            try setAgentApprovalStatus(messageID, allow ? "allowed" : "denied")
        } catch {
            try? setAgentApprovalStatus(messageID, "expired")
            try? updateAgentApprovalWait(pending.sessionID)
            throw error
        }
        try updateAgentApprovalWait(pending.sessionID)
    }

    func finishAgentApproval(_ id: UUID, status: String = "expired") throws {
        guard let pending = agentApprovals.removeValue(forKey: id) else { return }
        try setAgentApprovalStatus(id, status)
        try updateAgentApprovalWait(pending.sessionID)
    }
    private func setAgentApprovalStatus(_ id: UUID, _ status: String) throws {
        var message = try store.get(Message.self, id)
        if case .object(var payload) = message.payload { payload["status"] = .string(status); message.payload = .object(payload) }
        try store.save(message)
    }
    func expireAgentApprovals(_ sessionID: UUID) throws {
        for id in agentApprovals.filter({ $0.value.sessionID == sessionID }).map(\.key) { try finishAgentApproval(id) }
        agentApprovalClocks[sessionID] = nil
    }
    func recoverAgentApprovals() throws {
        // A saved card cannot authorize a new process after relaunch.
        for message in try store.all(Message.self) where message.isPendingAgentApproval { try setAgentApprovalStatus(message.id, "expired") }
    }
}
