import Foundation
import Testing
import GRDB

extension CoreTests {
    @Test func repositoriesKeepWorktreesPRTargetsAndRemovalBoundToTheirTasks() async throws {
        let f = try await Fixture()
        let legacy = try f.store.createTask(projectId: f.project.id, title: "Existing task")
        // Reconstruct v17 to catch lost repository identity when upgrading existing projects/tasks.
        try await f.store.db.write { db in
            try db.execute(sql: "ALTER TABLE task DROP COLUMN repositoryID")
            try db.execute(sql: "DROP TABLE projectRepository")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v18-project-repositories'")
        }
        let upgraded = try Store(root: f.store.root)
        #expect(try upgraded.get(WorkTask.self, legacy.id).repositoryID == f.project.id)
        #expect(try upgraded.repositories(f.project.id).first?.repoPath == f.project.repoPath)
        let core = Orchestrator(store: f.store, runner: f.runner)
        try await core.deleteTask(legacy.id)
        try f.store.workflow(for: f.project)
        var settings = try f.store.settings(); settings.paused = true; try f.store.saveSettings(settings)
        let secondary = f.root.appending(path: "second-clone")
        let remote = f.root.appending(path: "second-remote.git")
        _ = try await f.runner.run("git", ["init", "-b", "main", secondary.path])
        try "Second repository only".write(to: secondary.appending(path: "SECOND.md"), atomically: true, encoding: .utf8)
        _ = try await f.runner.run("git", ["add", "."], cwd: secondary.path)
        _ = try await f.runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Seed second"], cwd: secondary.path)
        try await core.addRepository(projectID: f.project.id, path: secondary.path)
        try await core.addRepository(projectID: f.project.id, path: secondary.path) // Picker retries never duplicate links.
        let links = try f.store.repositories(f.project.id)
        #expect(links.count == 2)
        var second = try #require(links.first { $0.id != f.project.id })
        // Supply a hosted fixture identity while every Git fetch/push stays on a local bare remote.
        _ = try await f.runner.run("git", ["init", "--bare", "--initial-branch=main", remote.path])
        _ = try await f.runner.run("git", ["remote", "add", "origin", remote.path], cwd: secondary.path)
        _ = try await f.runner.run("git", ["push", "origin", "main"], cwd: secondary.path)
        second.host = .github; second.remoteSlug = "fixture/second"; try f.store.save(second)
        do { _ = try f.store.createTask(projectId: f.project.id, title: "Ambiguous target"); Issue.record("Task silently picked a repository") } catch {}
        let intake: [[String: Any]] = [
            ["title": "First dependency", "description": "Change first", "dependsOnIndex": [Int](), "repositoryID": f.project.id.uuidString, "expectedFile": "README.md"],
            ["title": "Second dependent", "description": "Change second", "dependsOnIndex": [0], "repositoryID": second.id.uuidString, "expectedFile": "SECOND.md"]
        ]
        try JSONSerialization.data(withJSONObject: intake).write(to: f.control.appending(path: "repository-proposal.json"))
        settings.paused = false; try f.store.saveSettings(settings)
        try await core.sendProjectMessage(f.project.id, text: "Plan a change across both repositories")
        try await f.wait("multi-repository proposal") {
            try f.store.all(Proposal.self).count == 1 && f.store.session(for: f.project.id, ownerType: "project").status == "idle"
        }
        settings.paused = true; try f.store.saveSettings(settings)
        let proposal = try #require(f.store.all(Proposal.self).first)
        let first = try f.store.createTask(projectId: f.project.id, title: "First repo", repositoryID: f.project.id)
        let secondTask = try f.store.createTask(projectId: f.project.id, title: "Second repo", repositoryID: second.id)
        let proposed = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0, 1], dispatch: false)
        #expect(proposed[1].repositoryID == second.id && proposed[1].dependsOn == [proposed[0].id])
        #expect(try await !core.dependenciesReady(proposed[1]))
        for task in proposed { try await core.deleteTask(task.id) }
        var firstScope = first; firstScope.affectedPaths = ["."]
        var secondScope = secondTask; secondScope.affectedPaths = ["."]
        #expect(!firstScope.overlaps(secondScope))
        let firstWork = try await Workspace(store: f.store, runner: f.runner).prepare(first, project: f.store.project(for: first))
        let secondWork = try await Workspace(store: f.store, runner: f.runner).prepare(secondTask, project: f.store.project(for: secondTask))
        #expect(FileManager.default.fileExists(atPath: firstWork.worktreePath! + "/README.md"))
        #expect(!FileManager.default.fileExists(atPath: firstWork.worktreePath! + "/SECOND.md"))
        #expect(FileManager.default.fileExists(atPath: secondWork.worktreePath! + "/SECOND.md"))
        _ = try await Workspace(store: f.store, runner: f.runner).agentWritableRoots(secondWork, project: f.store.project(for: secondWork))
        do { try await core.removeRepository(second.id); Issue.record("Removed a repository with unfinished work") } catch {}
        let reopened = try Store(root: f.store.root)
        #expect(try reopened.project(for: secondWork).remoteSlug == "fixture/second")
        let head = try await f.runner.run("git", ["rev-parse", "HEAD"], cwd: secondWork.worktreePath).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await GitHub(runner: f.runner, root: f.store.root).open(task: secondWork, project: f.store.project(for: secondWork), summary: "Adds the requested feature.", base: "main", commitSHA: head)
        let calls = try String(contentsOf: f.control.appending(path: "gh-calls.jsonl"), encoding: .utf8)
        #expect(calls.split(separator: "\n").contains { $0.contains("\"create\"") && $0.contains("fixture/second") })
        try await core.deleteTask(secondTask.id)
        try await core.removeRepository(second.id)
        #expect(try f.store.repositories(f.project.id).map(\.id) == [f.project.id])
        #expect(FileManager.default.fileExists(atPath: secondary.appending(path: "SECOND.md").path))
        try await core.deleteTask(first.id)
        try await core.removeRepository(f.project.id)
        #expect(try f.store.repositories(f.project.id).isEmpty)
        do { _ = try f.store.createTask(projectId: f.project.id, title: "No repository"); Issue.record("Queued a task without a repository") } catch {}
        await core.shutdown(); try f.cleanup()
    }
}
