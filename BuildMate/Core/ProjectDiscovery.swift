import Foundation

struct DiscoveredProject: Sendable {
    var project: Project
    var authenticated: Bool
    var status: String
    var setupCommand: String?
}

struct ProjectDiscovery: Sendable {
    var runner = ProcessRunner()

    func inspect(path: String) async throws -> DiscoveredProject {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw CoreError.invalid("That folder does not exist. Choose an existing local clone.") }
        let top = try await runner.run("git", ["rev-parse", "--show-toplevel"], cwd: url.path, allowFailure: true)
        guard top.status == 0 else { throw CoreError.invalid("That folder is not a git working copy. Choose an existing local clone.") }
        let repo = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        let remote = try await runner.run("git", ["remote", "get-url", "origin"], cwd: repo.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Host
        let remotePath: String
        if let components = URLComponents(string: remote), let hostname = components.host {
            switch hostname.lowercased() {
            case "github.com": host = .github
            case "bitbucket.org": host = .bitbucket
            default: throw CoreError.invalid("Choose a GitHub or Bitbucket Cloud clone.")
            }
            remotePath = components.path
        } else if remote.hasPrefix("git@github.com:") {
            host = .github; remotePath = String(remote.dropFirst("git@github.com:".count))
        } else if remote.hasPrefix("git@bitbucket.org:") {
            host = .bitbucket; remotePath = String(remote.dropFirst("git@bitbucket.org:".count))
        } else { throw CoreError.invalid("Origin must point to GitHub or Bitbucket Cloud.") }
        var slug = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if slug.hasSuffix(".git") { slug.removeLast(4) }
        guard slug.split(separator: "/").count == 2 else { throw CoreError.invalid("The origin repository name is invalid.") }
        let remoteHead = try await runner.run("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo.path, allowFailure: true)
        let head = remoteHead.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var branch = remoteHead.status == 0 && head.hasPrefix("origin/") ? String(head.dropFirst(7)) : ""
        var signedIn = false
        var status = "Bitbucket integration requires verification. This project will stay paused."
        var setup: String? = "twg setup bitbucket"
        if host == .github {
            let auth = try await runner.run("gh", ["auth", "status", "--hostname", "github.com"], cwd: repo.path, allowFailure: true)
            signedIn = auth.status == 0
            status = signedIn ? "GitHub CLI is signed in" : "Sign in to GitHub CLI, then check again"
            setup = signedIn ? nil : auth.status == 127 ? "brew install gh && gh auth login" : "gh auth login"
            if auth.status == 127 { status = "GitHub CLI is not installed" }
            if signedIn {
                let result = try await runner.run("gh", ["repo", "view", slug, "--json", "nameWithOwner,defaultBranchRef"], cwd: repo.path)
                let data = try JSONDecoder().decode(JSON.self, from: Data(result.output.utf8))
                branch = data["defaultBranchRef"]["name"].string ?? branch
            }
        }
        guard !branch.isEmpty else { throw CoreError.invalid("Default branch is unknown. Run git remote set-head origin -a in Terminal, then check again.") }
        let local = try await runner.run("git", ["rev-parse", "--verify", "refs/heads/" + branch], cwd: repo.path, allowFailure: true)
        guard local.status == 0 else { throw CoreError.invalid("Check out the default branch (\(branch)) locally before adding this project.") }
        var project = Project(name: slug, repoPath: repo.path, host: host, remoteSlug: slug, defaultBranch: branch)
        project.paused = !signedIn
        return DiscoveredProject(project: project, authenticated: signedIn, status: status, setupCommand: setup)
    }
}
