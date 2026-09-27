import Foundation
import GRDB
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

extension Store {
    /// Copy before saving: a moved Desktop file must not break a resumed conversation.
    func prepareAttachments(_ urls: [URL], projectID: UUID, ownerID: UUID, messageID: UUID) throws -> [Attachment] {
        let directory = root.appending(path: "projects/\(projectID)/media/\(ownerID)/\(messageID)")
        var result: [Attachment] = []
        do {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
                guard url.isFileURL, values.isRegularFile == true else { throw CoreError.invalid("Attach files, not folders or applications.") }
                guard let size = values.fileSize, size <= 50 * 1024 * 1024 else { throw CoreError.invalid("Each attachment must be 50 MB or smaller.") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appending(path: "\(UUID())-\(url.lastPathComponent)")
                try FileManager.default.copyItem(at: url, to: path)
                var attachment = Attachment(ownerType: "message", ownerId: messageID, kind: "file", path: path.path, filename: url.lastPathComponent, byteSize: size)
                if values.contentType?.conforms(to: .image) == true {
                    guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                        throw CoreError.invalid("Could not read image \(url.lastPathComponent).")
                    }
                    let vision = directory.appending(path: "\(attachment.id)-image.png")
                    guard let output = CGImageDestinationCreateWithURL(vision as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CoreError.invalid("Could not prepare the attached image.") }
                    CGImageDestinationAddImage(output, image, nil)
                    guard CGImageDestinationFinalize(output) else { throw CoreError.invalid("Could not save the attached image.") }
                    attachment.kind = "image"; attachment.frames = [vision.path]
                }
                if values.contentType?.conforms(to: .movie) == true {
                    let asset = AVURLAsset(url: path)
                    let duration = asset.duration.seconds
                    guard duration.isFinite, duration > 0 else { throw CoreError.invalid("Could not read video \(url.lastPathComponent).") }
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 1600, height: 1600)
                    for index in 0..<6 {
                        let time = duration * Double(index) / 6
                        let frame = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
                        let url = directory.appending(path: "\(attachment.id)-frame-\(index).png")
                        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CoreError.invalid("Could not prepare video frames.") }
                        CGImageDestinationAddImage(output, frame, nil)
                        guard CGImageDestinationFinalize(output) else { throw CoreError.invalid("Could not save video frame.") }
                        attachment.frames.append(url.path)
                    }
                    attachment.kind = "video"
                    attachment.transcript = "Six evenly spaced video frames, in chronological order. Audio has not been transcribed."
                }
                result.append(attachment)
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @discardableResult
    func saveChatMessage(_ message: Message, files: [URL], projectID: UUID, ownerID: UUID) throws -> [Attachment] {
        guard files.count <= 20 else { throw CoreError.invalid("Attach up to 20 files per message.") }
        let attachments = try prepareAttachments(files, projectID: projectID, ownerID: ownerID, messageID: message.id)
        do { try db.write { db in
            try message.insert(db)
            for attachment in attachments { try attachment.insert(db) }
        } } catch {
            discardPreparedAttachments(attachments)
            throw error
        }
        return attachments
    }

    func discardPreparedAttachments(_ attachments: [Attachment]) {
        if let first = attachments.first { try? FileManager.default.removeItem(at: URL(fileURLWithPath: first.path).deletingLastPathComponent()) }
    }

    func chatAttachments(sessionID: UUID) throws -> [Attachment] {
        try db.read { db in
            try Attachment.fetchAll(db, sql: "SELECT attachment.* FROM attachment JOIN message ON attachment.ownerId = message.id WHERE attachment.ownerType = 'message' AND message.sessionId = ? ORDER BY message.createdAt, attachment.rowid", arguments: [sessionID])
        }
    }
    func taskAttachments(_ taskID: UUID, sessionID: UUID) throws -> [Attachment] {
        try all(Attachment.self).filter { $0.ownerType == "task" && $0.ownerId == taskID } + chatAttachments(sessionID: sessionID)
    }

    /// Keep filename/history tombstones; remove only app-owned attachment bytes, never originals or proof.
    func removeMergedTaskAttachments(_ taskID: UUID) throws {
        let task = try get(WorkTask.self, taskID)
        guard task.state == .done else { return }
        let session = try session(for: taskID)
        for var attachment in try taskAttachments(taskID, sessionID: session.id) where attachment.removedAt == nil {
            try removeAttachmentFiles(&attachment, projectID: task.projectId)
        }
    }
    func removeCompletedProjectAttachments(_ projectID: UUID) throws {
        let tasks = Dictionary(uniqueKeysWithValues: try all(WorkTask.self).filter { $0.projectId == projectID }.map { ($0.id, $0) })
        func finished(_ id: UUID, visited: Set<UUID> = []) -> Bool {
            guard let task = tasks[id], !visited.contains(id) else { return false }
            return task.state == .done || (task.state == .canceled && !task.replacedBy.isEmpty && task.replacedBy.allSatisfy { finished($0, visited: visited.union([id])) })
        }
        for task in tasks.values where task.state == .canceled && finished(task.id) {
            let session = try session(for: task.id)
            for var attachment in try taskAttachments(task.id, sessionID: session.id) where attachment.removedAt == nil { try removeAttachmentFiles(&attachment, projectID: projectID) }
        }
        let attachments = try all(Attachment.self)
        let session = try session(for: projectID, ownerType: "project")
        guard !["running", "waiting", "queued"].contains(session.status) else { return }
        for var source in try chatAttachments(sessionID: session.id) where source.removedAt == nil {
            let copies = attachments.filter { $0.sourceAttachmentId == source.id && $0.ownerType == "task" }
            // Unassigned files stay in chat. One merged task cannot remove references needed by another.
            if !copies.isEmpty && copies.allSatisfy({ finished($0.ownerId) }) {
                try removeAttachmentFiles(&source, projectID: projectID)
            }
        }
    }

    private func removeAttachmentFiles(_ attachment: inout Attachment, projectID: UUID) throws {
        let media = root.appending(path: "projects/\(projectID)/media").resolvingSymlinksInPath().path + "/"
        for path in [attachment.path] + attachment.frames {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(media) else { throw CoreError.invalid("Attachment cleanup refused a file outside app media storage.") }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        attachment.removedAt = Date(); try save(attachment)
    }

}
