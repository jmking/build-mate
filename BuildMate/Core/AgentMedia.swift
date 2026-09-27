import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension Orchestrator {
    /// Import only a native output path from this parent's current turn, never a path in model text.
    func consumeGeneratedImage(_ event: AgentEvent, session: Session) throws {
        guard case .image(let id, let savedPath, let completed) = event.kind else { return }
        guard let thread = session.providerSessionID, event.sessionID == thread,
              let turn = session.currentTurn, event.turnID == turn,
              let itemID = id else { return }
        let exists = try store.db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM message WHERE sessionId = ?
                  AND json_extract(payload, '$.generatedImageItemId') = ?
                  AND json_extract(payload, '$.generatedImageTurnId') = ?)
                """, arguments: [session.id, itemID, turn]) ?? false
        }
        guard !exists else { return }
        var message = Message(sessionId: session.id, role: "agent", body: "", payload: .object([
            "generatedImageItemId": .string(itemID), "generatedImageTurnId": .string(turn)
        ]))
        do {
            guard completed, let path = savedPath,
                  path.hasPrefix("/"), !path.contains("\0") else {
                throw CoreError.invalid("No saved image")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 50 * 1024 * 1024,
                  values.contentType?.conforms(to: .image) == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw CoreError.invalid("Invalid saved image")
            }
            let projectID: UUID
            if session.ownerType == "project" { projectID = session.ownerId }
            else if session.ownerType == "task" { projectID = try store.get(WorkTask.self, session.ownerId).projectId }
            else { throw CoreError.invalid("Unknown conversation owner") }
            let attachments = try store.saveChatMessage(message, files: [url], projectID: projectID, ownerID: session.ownerId)
            try store.acknowledgeInput(session: session, ids: attachments.map(\.id))
        } catch {
            // Do not persist paths, prompts, base64 results or tool error details.
            message.role = "system"; message.kind = "error"
            message.body = completed
                ? "The generated image could not be attached. Ask the agent to save it as a local image and try again."
                : "Image generation did not complete. Ask the agent to try again."
            try store.save(message)
        }
    }
}
