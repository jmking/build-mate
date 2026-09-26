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
        _ = try await runner.run("git", ["push", "-u", "origin", branch], cwd: cwd)
        let file = root.appending(path: "projects/\(project.id)/pr-\(task.id).md")
        try summary.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run("gh", ["pr", "create", "--repo", project.remoteSlug, "--base", base, "--head", branch, "--title", task.title, "--body-file", file.path], cwd: cwd)
        let url = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = try await runner.run("gh", ["pr", "view", url, "--repo", project.remoteSlug, "--json", "number,url,baseRefName"], cwd: cwd)
        let value = try JSONDecoder().decode(JSON.self, from: Data(detail.output.utf8))
        guard let number = value["number"].int, let canonical = value["url"].string else { throw CoreError.invalid("Invalid GitHub PR response") }
        return PullRequest(number: number, url: canonical, baseBranch: value["baseRefName"].string ?? base)
    }
    func merged(task: WorkTask, project: Project) async throws -> Bool {
        guard project.host == .github, let pr = task.pr else { return false }
        let result = try await runner.run("gh", ["pr", "view", String(pr.number), "--repo", project.remoteSlug, "--json", "state"], cwd: task.worktreePath)
        return try JSONDecoder().decode(JSON.self, from: Data(result.output.utf8))["state"].string == "MERGED"
    }
}
