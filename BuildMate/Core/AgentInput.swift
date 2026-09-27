import Foundation
import GRDB

/// Native agent sessions already retain their transcript. Track accepted inputs across app restarts.
struct AgentDelivery: Record {
    static let databaseTableName = "agentDelivery"
    var id: UUID
    var provider: AgentProvider = .codex
    var threadId: String
    var context = ""
    var deliveredIDs: [UUID] = []
}

struct AgentInput {
    var text: String
    var context: String
    var ids: [UUID]
    var attachments: [Attachment]
}

extension Store {
    func hasUndeliveredMessages(_ session: Session) throws -> Bool {
        let delivery = try db.read { try AgentDelivery.fetchOne($0, key: session.id) }
        let sent = Set(delivery?.provider == session.provider && delivery?.threadId == session.providerSessionID ? delivery?.deliveredIDs ?? [] : [])
        return try db.read { try Message.filter(Column("sessionId") == session.id && Column("role") == "user").fetchAll($0) }
            .contains { !sent.contains($0.id) }
    }
    func agentInput(session: Session, context: String, attachments: [Attachment]) throws -> AgentInput {
        let delivery = try db.read { try AgentDelivery.fetchOne($0, key: session.id) }
        let sameThread = delivery?.provider == session.provider && delivery?.threadId == session.providerSessionID
        let sent = Set(sameThread ? delivery?.deliveredIDs ?? [] : [])
        let messages = try db.read {
            try Message.filter(Column("sessionId") == session.id && Column("role") == "user").order(Column("createdAt")).fetchAll($0)
        }.filter { !sent.contains($0.id) }
        let answers = session.ownerType == "task" ? try db.read {
            try Question.filter(Column("taskId") == session.ownerId).order(Column("answeredAt")).fetchAll($0)
        }.filter { $0.answer != nil && $0.answeredBy != "taskEdit" && !sent.contains($0.id) } : []
        let projectAnswers = session.ownerType == "project" ? try db.read {
            try Message.filter(Column("sessionId") == session.id && Column("kind") == "question").order(Column("createdAt")).fetchAll($0)
        }.filter { $0.payload["answer"].string != nil && !sent.contains($0.id) } : []
        let files = attachments.filter { $0.removedAt == nil && !sent.contains($0.id) }
        var parts: [String] = []
        if !sameThread || delivery?.context != context { parts.append("Current task guidance (supersedes earlier versions):\n" + context) }
        if !messages.isEmpty { parts.append("New user messages (in order):\n" + messages.map(\.body).joined(separator: "\n\n")) }
        if !answers.isEmpty { parts.append("New answers:\n" + answers.map { "\($0.prompt): \($0.answer!)" }.joined(separator: "\n")) }
        if !projectAnswers.isEmpty { parts.append("New answers:\n" + projectAnswers.map { "\($0.body): \($0.payload["answer"].string!)" }.joined(separator: "\n")) }
        if messages.isEmpty && answers.isEmpty && projectAnswers.isEmpty { parts.append("Continue the current request from the existing conversation. Do not repeat completed work.") }
        return AgentInput(text: parts.joined(separator: "\n\n"), context: context,
                          ids: messages.map(\.id) + answers.map(\.id) + projectAnswers.map(\.id) + files.map(\.id), attachments: files)
    }

    /// Merge with concurrent steering acknowledgements; failed requests leave inputs pending.
    func acknowledgeInput(session: Session, ids: [UUID], context: String? = nil) throws {
        guard let thread = session.providerSessionID else { return }
        try db.write { db in
            var delivery = try AgentDelivery.fetchOne(db, key: session.id) ?? AgentDelivery(id: session.id, provider: session.provider, threadId: thread)
            if delivery.provider != session.provider || delivery.threadId != thread { delivery = AgentDelivery(id: session.id, provider: session.provider, threadId: thread) }
            let sent = Set(delivery.deliveredIDs)
            delivery.deliveredIDs += ids.filter { !sent.contains($0) }
            if let context { delivery.context = context }
            try delivery.save(db)
        }
    }
}
