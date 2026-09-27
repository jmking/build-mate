import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension Orchestrator {
    /// Import only a native output path from this parent's current turn, never a path in model text.
    func consumeGeneratedImage(_ event: JSON, session: Session) throws -> Bool {
        let params = event["params"], item = params["item"]
        guard event["method"].string == "item/completed", item["type"].string == "imageGeneration" else { return false }
        guard let thread = session.codexThreadId, params["threadId"].string == thread,
              let turn = session.currentTurn, params["turnId"].string == turn,
              let itemID = item["id"].string else { return true }
        let exists = try store.db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM message WHERE sessionId = ?
                  AND json_extract(payload, '$.generatedImageItemId') = ?
                  AND json_extract(payload, '$.generatedImageTurnId') = ?)
                """, arguments: [session.id, itemID, turn]) ?? false
        }
        guard !exists else { return true }
        var message = Message(sessionId: session.id, role: "agent", body: "", payload: .object([
            "generatedImageItemId": .string(itemID), "generatedImageTurnId": .string(turn)
        ]))
        do {
            guard item["status"].string == "completed", let path = item["savedPath"].string,
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
            message.body = item["status"].string == "completed"
                ? "The generated image could not be attached. Ask the agent to save it as a local image and try again."
                : "Image generation did not complete. Ask the agent to try again."
            try store.save(message)
        }
        return true
    }
}
