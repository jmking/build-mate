import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import ImageIO
import CoreGraphics

/// Shared by both composers so capture, file picking and removal behave identically.
struct ChatAttachmentControls: View {
    @Binding var files: [URL]
    let root: URL
    @State private var choosing = false
    @State private var capturing = false
    @State private var error: String?
    var body: some View {
        HStack(spacing: 6) {
            Button("Attach Files", systemImage: "paperclip") { choosing = true }
                .help("Attach images or files").accessibilityIdentifier("attach-files")
            Menu {
                Button("Capture Window…", systemImage: "macwindow") { capture(window: true) }
                    .help("Click a window to attach a screenshot; Escape cancels")
                Button("Capture Area…", systemImage: "viewfinder") { capture(window: false) }
                    .help("Draw a rectangle on screen to attach a screenshot; Escape cancels")
            } label: { Label("Screenshot", systemImage: "camera") }
                .menuIndicator(.hidden).help("Attach a screenshot of a window or selected area")
                .accessibilityLabel("Screenshot").accessibilityIdentifier("attach-screenshot")
        }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
            .disabled(capturing)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { files.append(contentsOf: try result.get()) } catch { self.error = error.localizedDescription }
            }
            .alert("Unable to attach screenshot or file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
    private func capture(window: Bool) {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = "Allow Build Mate in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            return
        }
        capturing = true
        let target = NSApp.keyWindow
        Task { @MainActor in
            defer { capturing = false; NSApp.activate(); target?.makeKeyAndOrderFront(nil) }
            do {
                let directory = root.appending(path: "attachment-drafts")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "Screenshot-\(UUID()).png")
                // Native macOS UI handles display scaling, window picking, selection and Escape.
                NSApp.hide(nil)
                let result = try await ProcessRunner().run("/usr/sbin/screencapture", ["-i", "-d", window ? "-w" : "-s", "-x", "-o", url.path], timeout: 300, allowFailure: true)
                if FileManager.default.fileExists(atPath: url.path) { files.append(url) }
                else if result.status != 0 {
                    // Escape also exits without a file; cancellation must not create an attachment.
                    // The native capture UI presents permission errors itself.
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ChatAttachmentTray: View {
    @Binding var files: [URL]
    let root: URL
    @State private var preview: URL?
    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 8) {
                            Button { preview = url } label: {
                                HStack(spacing: 8) {
                                    AttachmentThumbnail(url: url).frame(width: 40, height: 36).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                    Text(url.lastPathComponent).lineLimit(1).frame(maxWidth: 160)
                                }
                            }.buttonStyle(.plain).help("Preview \(url.lastPathComponent)")
                            Button("Remove attachment", systemImage: "xmark.circle.fill") {
                                files.remove(at: index)
                                removeDraftCapture(url, root: root)
                            }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove \(url.lastPathComponent)").accessibilityLabel("Remove \(url.lastPathComponent)")
                        }.font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.scrollIndicators(.hidden).quickLookPreview($preview)
        }
    }
}

struct MessageAttachments: View {
    @Environment(AppModel.self) private var model
    let messageID: UUID
    var ownerType = "message"
    @State private var preview: URL?
    var body: some View {
        ForEach(model.snapshot.attachments.filter { $0.ownerType == ownerType && $0.ownerId == messageID }) { attachment in
            if attachment.removedAt != nil {
                Label("\(attachment.filename) · attachment removed", systemImage: "doc")
                    .font(.caption).opacity(0.7)
            } else {
            Button { preview = URL(fileURLWithPath: attachment.path) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    if attachment.kind == "image" {
                        AttachmentThumbnail(url: URL(fileURLWithPath: attachment.path))
                            .frame(maxWidth: 220, maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Label(attachment.filename, systemImage: attachment.kind == "image" ? "photo" : "doc")
                        .font(.caption).lineLimit(2)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Preview \(attachment.filename)").accessibilityLabel("Attachment: \(attachment.filename)")
            }
        }.quickLookPreview($preview)
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").font(.title2).foregroundStyle(.secondary) }
        }.task(id: url) {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                image = NSImage(cgImage: thumbnail, size: .zero)
            }
        }
    }
}

func removeDraftCapture(_ url: URL, root: URL) {
    if url.deletingLastPathComponent().standardizedFileURL == root.appending(path: "attachment-drafts").standardizedFileURL {
        try? FileManager.default.removeItem(at: url)
    }
}

struct ChatAttachmentDrop: ViewModifier {
    @Binding var files: [URL]
    let root: URL
    var enabled = true
    @State private var targeted = false
    @State private var error: String?
    func body(content: Content) -> some View {
        content
            .overlay { if targeted && enabled { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, failure in
                            Task { @MainActor in
                                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { files.append(url) }
                                else { error = failure?.localizedDescription ?? "Could not read the dropped file." }
                            }
                        }
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        provider.loadDataRepresentation(forTypeIdentifier: type) { data, failure in
                            Task { @MainActor in
                                do {
                                    guard let data else { throw failure ?? CoreError.invalid("Could not read the dropped image.") }
                                    let directory = root.appending(path: "attachment-drafts")
                                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                    let url = directory.appending(path: "Image-\(UUID()).\(UTType(type)?.preferredFilenameExtension ?? "png")")
                                    try data.write(to: url); files.append(url)
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                return !providers.isEmpty
            }
            .alert("Unable to attach file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}
