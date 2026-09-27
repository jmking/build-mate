import Foundation

struct Workspace: Sendable {
    let store: Store
    let runner: ProcessRunner

    /// Fetch the actual host branch without touching the user's checked-out files or local branch.
    func baseRevision(_ project: Project) async throws -> String {
        let ref: String
        if project.host == .local { ref = "refs/heads/\(project.defaultBranch)" }
        else {
            ref = "refs/remotes/origin/\(project.defaultBranch)"
            _ = try await runner.run("git", ["fetch", "--no-tags", "origin", "+refs/heads/\(project.defaultBranch):\(ref)"], cwd: project.repoPath)
        }
        return try await runner.run("git", ["rev-parse", "--verify", "\(ref)^{commit}"], cwd: project.repoPath).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func prepare(_ original: WorkTask, project: Project) async throws -> WorkTask {
        var task = original
        if task.worktreePath == nil {
            let slug = task.title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            task.branchName = project.settings.branchPrefix + "\(task.number)-" + (slug.isEmpty ? "task" : String(slug.prefix(60)))
            task.worktreePath = store.root.appending(path: "worktrees/\(project.id)/\(task.number)").path
            try store.save(task) // Intent survives a crash between git and SQLite.
        }
        let path = task.worktreePath!
        try ensureOwned(path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            var base = try await baseRevision(project)
            if let baseId = task.stackOn {
                let parent = try store.get(WorkTask.self, baseId)
                if parent.state != .done { base = parent.branchName ?? base }
            }
            let exists = try await runner.run("git", ["show-ref", "--verify", "--quiet", "refs/heads/\(task.branchName!)"], cwd: project.repoPath, allowFailure: true)
            if exists.status != 0 {
                task.baseCommitSHA = try await runner.run("git", ["rev-parse", "--verify", "\(base)^{commit}"], cwd: project.repoPath).output.trimmingCharacters(in: .whitespacesAndNewlines)
                try store.save(task)
            }
            let arguments = exists.status == 0 ? ["worktree", "add", path, task.branchName!] : ["worktree", "add", "-b", task.branchName!, path, base]
            _ = try await runner.run("git", arguments, cwd: project.repoPath)
        }
        let top = try await runner.run("git", ["rev-parse", "--show-toplevel"], cwd: path)
        let actual = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        guard actual == URL(fileURLWithPath: path).resolvingSymlinksInPath() else { throw CoreError.invalid("Unexpected existing worktree directory") }
        let branch = try await runner.run("git", ["branch", "--show-current"], cwd: path)
        guard branch.output.trimmingCharacters(in: .whitespacesAndNewlines) == task.branchName else { throw CoreError.invalid("Worktree branch changed; review before resuming") }
        if !task.workspaceReady {
            try await runner.hook(project.settings.hooks.afterCreate, cwd: path, timeout: project.settings.hooks.timeoutSeconds)
            try ensureOwned(path)
            task = try store.get(WorkTask.self, task.id)
            task.workspaceReady = true
            try store.save(task)
        }
        return task
    }
    func remove(_ task: WorkTask, project: Project, discardChanges: Bool = false) async throws {
        guard let path = task.worktreePath else { return }
        try ensureOwned(path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try await runner.hook(project.settings.hooks.beforeRemove, cwd: path, timeout: project.settings.hooks.timeoutSeconds)
        try ensureOwned(path)
        // Only explicit task deletion discards unfinished work; automatic cleanup remains conservative.
        let arguments = ["worktree", "remove"] + (discardChanges ? ["--force"] : []) + [path]
        _ = try await runner.run("git", arguments, cwd: project.repoPath)
    }

    func agentWritableRoots(_ task: WorkTask, project: Project) async throws -> [String] {
        guard let path = task.worktreePath, let branch = task.branchName else {
            throw CoreError.invalid("Task worktree is unavailable")
        }
        try ensureOwned(path)
        let ref = "refs/heads/" + branch
        let head = try await runner.run("git", ["symbolic-ref", "--quiet", "HEAD"], cwd: path)
        guard head.output.trimmingCharacters(in: .whitespacesAndNewlines) == ref else {
            throw CoreError.invalid("Worktree branch changed; review before resuming")
        }
        let metadata = try await runner.run("git", ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
            "--git-path", "objects", "--git-path", ref, "--git-path", "logs/" + ref], cwd: path)
        let paths = metadata.output.split(separator: "\n").map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
        let repository = try await runner.run("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: project.repoPath)
        let common = URL(fileURLWithPath: repository.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        guard paths.count == 5, paths[1] == common, paths[0].hasPrefix(common + "/worktrees/"),
              paths.dropFirst(2).allSatisfy({ $0.hasPrefix(common + "/") }) else {
            throw CoreError.invalid("Task Git metadata does not belong to this project")
        }
        // Linked worktree metadata lives outside cwd. Grant only its private index/HEAD,
        // shared objects, and this branch's ref/reflog (including atomic-write locks).
        // The clone's files, Git config/hooks, and other branch refs stay read-only.
        return [path, paths[0], paths[2], paths[3], paths[3] + ".lock", paths[4], paths[4] + ".lock"]
    }

    func ensureOwned(_ path: String) throws {
        let root = store.root.resolvingSymlinksInPath()
        let supplied = URL(fileURLWithPath: path).standardizedFileURL.path
        let originalRoot = store.root.standardizedFileURL.path + "/"
        let candidate = supplied.hasPrefix(originalRoot)
            ? root.appending(path: String(supplied.dropFirst(originalRoot.count)))
            : URL(fileURLWithPath: supplied)
        let base = root.appending(path: "worktrees").path + "/"
        // Check each parent: Foundation may leave a nonexistent leaf's symlinks unresolved.
        guard candidate.path.hasPrefix(base) else { throw CoreError.invalid("Worktree is outside Build Mate storage") }
        var cursor = root
        for component in candidate.path.dropFirst(root.path.count + 1).split(separator: "/") {
            cursor.append(path: String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw CoreError.invalid("Worktree is outside Build Mate storage: symbolic-link parent")
            }
        }
    }
}
