import Foundation

/// Milestone 2 uses only the host operations needed by the first lifecycle.
/// Full watch mode and the second provider belong to milestone 5.
struct GitHub: Sendable {
    let runner: ProcessRunner
    let root: URL

    func open(task: WorkTask, project: Project, summary: String, base: String) async throws -> PullRequest {
        guard project.host == .github else { throw CoreError.invalid("Set up twg; Bitbucket provider awaits its authenticated spike") }
        guard let branch = task.branchName, let cwd = task.worktreePath else { throw CoreError.invalid("Missing branch") }
        // Recover an already-created PR after an interrupted response without duplicating it.
        let existing = try await runner.run("gh", ["pr", "list", "--repo", project.remoteSlug, "--head", branch, "--state", "open", "--json", "number,url,baseRefName"], cwd: cwd)
        let values = try JSONDecoder().decode(JSON.self, from: Data(existing.output.utf8)).array
        if let value = values.first, let number = value["number"].int, let url = value["url"].string {
            return PullRequest(number: number, url: url, baseBranch: value["baseRefName"].string ?? base)
        }
        let body = try Self.changeDescription(summary)
        _ = try await runner.run("git", ["push", "-u", "origin", branch], cwd: cwd)
        let file = root.appending(path: "projects/\(project.id)/pr-\(task.id).md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run("gh", ["pr", "create", "--repo", project.remoteSlug, "--base", base, "--head", branch, "--title", task.title, "--body-file", file.path], cwd: cwd)
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = try await runner.run("gh", ["pr", "view", url, "--repo", project.remoteSlug, "--json", "number,url,baseRefName"], cwd: cwd)
        let value = try JSONDecoder().decode(JSON.self, from: Data(detail.output.utf8))
        guard let number = value["number"].int, let canonical = value["url"].string else { throw CoreError.invalid("Invalid GitHub PR response") }
        return PullRequest(number: number, url: canonical, baseBranch: value["baseRefName"].string ?? base)
    }

    /// A PR contains only the change description, never the full review-evidence report.
    private static func changeDescription(_ summary: String) throws -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Durable older threads may have encoded the report more than once.
        for _ in 0..<5 {
            if text.hasPrefix("```json\n"), text.hasSuffix("```") {
                text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { break }
            guard let report = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else {
                if text.hasPrefix("{") { break } // Do not publish a malformed JSON report either.
                return text
            }
            switch report {
            case .object(let fields):
                guard let changes = fields["changes"] ?? fields["summary"] else {
                    throw CoreError.invalid("The review report has no change description. Ask the agent for a short Markdown summary before opening the pull request.")
                }
                text = changes.string ?? changes.text
            case .array(let changes):
                let bullets = changes.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !bullets.isEmpty, bullets.count == changes.count, bullets.allSatisfy({ !$0.isEmpty }) else { break }
                return bullets.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
            case .string(let description): text = description
            default: break
            }
        }
        throw CoreError.invalid("The review summary is not a usable change description. Ask the agent for a short Markdown summary before opening the pull request.")
    }

    func merged(task: WorkTask, project: Project) async throws -> Bool {
        guard project.host == .github, let pr = task.pr else { return false }
        let result = try await runner.run("gh", ["pr", "view", String(pr.number), "--repo", project.remoteSlug, "--json", "state"], cwd: task.worktreePath)
        return try JSONDecoder().decode(JSON.self, from: Data(result.output.utf8))["state"].string == "MERGED"
    }
}
