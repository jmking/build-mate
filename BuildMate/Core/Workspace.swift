import Foundation

struct Workspace: Sendable {
    let store: Store
    let runner: ProcessRunner

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
            var base = project.defaultBranch
            if let baseId = task.stackOn {
                let parent = try store.get(WorkTask.self, baseId)
                if parent.state != .done { base = parent.branchName ?? base }
            }
            let exists = try await runner.run("git", ["show-ref", "--verify", "--quiet", "refs/heads/\(task.branchName!)"], cwd: project.repoPath, allowFailure: true)
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
    func remove(_ task: WorkTask, project: Project) async throws {
        guard let path = task.worktreePath else { return }
        try ensureOwned(path)
        try await runner.hook(project.settings.hooks.beforeRemove, cwd: path, timeout: project.settings.hooks.timeoutSeconds)
        try ensureOwned(path)
        // No --force: uncommitted work must never disappear during cleanup.
        _ = try await runner.run("git", ["worktree", "remove", path], cwd: project.repoPath)
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
