import Foundation

struct DiscoveredProject: Sendable {
    var project: Project
    var authenticated: Bool
    var status: String
    var setupCommand: String?
}

struct ProjectDiscovery: Sendable {
    var runner = ProcessRunner()

    func create(path: String) async throws -> DiscoveredProject {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("Choose a folder for the new project.") }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue, try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
                throw CoreError.invalid("Choose a new or empty folder. To use an existing repository, choose Add Existing.")
            }
        }
        let parent = exists ? folder : folder.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError.invalid("The parent folder does not exist. Choose an existing parent folder.")
        }
        let enclosing = try await runner.run("git", ["rev-parse", "--git-dir"], cwd: parent.path, allowFailure: true)
        guard enclosing.status != 0 else { throw CoreError.invalid("Choose a folder outside an existing Git repository.") }
        if !exists { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        _ = try await runner.run("git", ["init", "--initial-branch=main", "."], cwd: folder.path)
        // An empty commit gives worktrees a base without adding generated project files.
        _ = try await runner.run("git", ["-c", "user.name=Build Mate", "-c", "user.email=build-mate@localhost",
            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--allow-empty", "-m", "Initial commit"], cwd: folder.path)
        return try await inspect(path: folder.path)
    }

    func inspect(path: String) async throws -> DiscoveredProject {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw CoreError.invalid("That folder does not exist. Choose an existing local clone.") }
        let top = try await runner.run("git", ["rev-parse", "--show-toplevel"], cwd: url.path, allowFailure: true)
        guard top.status == 0 else { throw CoreError.invalid("That folder is not a git working copy. Choose an existing local clone.") }
        let repo = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        let origin = try await runner.run("git", ["remote", "get-url", "origin"], cwd: repo.path, allowFailure: true)
        if origin.status != 0 {
            let head = try await runner.run("git", ["symbolic-ref", "--short", "HEAD"], cwd: repo.path, allowFailure: true)
            let branch = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try await runner.run("git", ["rev-parse", "--verify", "HEAD"], cwd: repo.path, allowFailure: true)
            guard head.status == 0, commit.status == 0 else { throw CoreError.invalid("Check out a branch and make an initial commit before adding this repository.") }
            let project = Project(name: repo.lastPathComponent, repoPath: repo.path, host: .local, remoteSlug: "", defaultBranch: branch)
            return DiscoveredProject(project: project, authenticated: true, status: "Local repository — no remote", setupCommand: nil)
        }
        let remote = origin.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
