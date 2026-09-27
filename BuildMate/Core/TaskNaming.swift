import Foundation

extension Orchestrator {
    /// Naming has no worktree, lifecycle tools or durable session; failure retains the local title.
    func generateTitle(for description: String, provider: AgentProvider) async -> String {
        let client = provider.makeRunner()
        let directory = store.root.appending(path: "title-drafts/\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await client.start(runner: runner, cwd: directory.path, timeout: 5)
            let title = try await client.suggestTitle(description, cwd: directory.path)
            await client.stop()
            return Self.shortTitle(title)
        } catch { /* Keep the already-saved provisional title on failure. */ }
        await client.stop()
        return Self.provisionalTitle(description)
    }

    nonisolated static func provisionalTitle(_ description: String) -> String {
        let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? description
        let firstSentence = firstLine.components(separatedBy: ". ").first ?? firstLine
        return Self.shortTitle(firstSentence)
    }

    nonisolated private static func shortTitle(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = words.joined(separator: " ")
        if normalized.count <= 80 { return normalized }
        var title = ""
        for word in words {
            let next = title.isEmpty ? word : title + " " + word
            if next.count > 79 { return title.isEmpty ? String(word.prefix(79)) + "…" : title + "…" }
            title = next
        }
        return title
    }
}
