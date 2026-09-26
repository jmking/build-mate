import Foundation
import Testing

@MainActor
struct ShellTests {
    @Test func projectDiscoveryAndShellActionsPersistWithoutDispatchingBacklog() async throws {
        let f = try await CoreTests.Fixture()
        _ = try await f.runner.run("git", ["remote", "set-url", "origin", "git@github.com:fixture/repo.git"], cwd: f.repo.path)
        _ = try await f.runner.run("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: f.repo.path)
        let discovery = ProjectDiscovery(runner: f.runner)
        try f.marker("signed-out")
        let unauthenticated = try await discovery.inspect(path: f.repo.path)
        #expect(!unauthenticated.authenticated && unauthenticated.project.paused)
        #expect(unauthenticated.setupCommand == "gh auth login")
        try FileManager.default.removeItem(at: f.control.appending(path: "signed-out"))
        let discovered = try await discovery.inspect(path: f.repo.path)
        #expect(discovered.authenticated && discovered.project.host == .github)
        #expect(discovered.project.defaultBranch == "main" && discovered.project.remoteSlug == "fixture/repo")
        let uiStore = try Store(root: f.root.appending(path: "shell-data"))
        var settings = AppSettings(); settings.paused = true; try uiStore.saveSettings(settings)
        let model = AppModel(store: uiStore)
        try model.add(discovered)
        await model.refresh()
        #expect(model.selectedProject?.id == discovered.project.id)
        do { try model.add(discovered); Issue.record("Duplicate clone accepted") } catch {}
        try await model.createTask(projectID: discovered.project.id, title: "  Make output readable  ", description: "Keep it compact", start: false)
        await model.refresh()
        let task = try #require(model.selectedTask)
        #expect(task.state == .backlog && task.title == "Make output readable")
        #expect(task.worktreePath == nil)
        let session = try uiStore.session(for: task.id)
        try uiStore.save(Message(sessionId: session.id, role: "agent", body: "A persisted transcript"))
        await model.refresh()
        #expect(model.snapshot.messages.first?.body == "A persisted transcript")
        let restored = AppModel(store: uiStore)
        let observer = Task { await restored.observe() }
        let deadline = Date().addingTimeInterval(5)
        while restored.selectedTask?.id != task.id && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(restored.selectedTask?.id == task.id)
        observer.cancel(); await observer.value; await restored.core.shutdown()
        #expect(restored.snapshot.messages.first?.body == "A persisted transcript")
        _ = try await f.runner.run("git", ["remote", "set-url", "origin", "https://bitbucket.org/team/project.git"], cwd: f.repo.path)
        let bitbucket = try await discovery.inspect(path: f.repo.path)
        #expect(bitbucket.project.host == .bitbucket && bitbucket.project.paused && !bitbucket.authenticated)
        #expect(bitbucket.project.remoteSlug == "team/project")
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        await model.core.shutdown()
        try uiStore.db.close()
        try f.store.db.close()
        try f.cleanup()
    }
}
