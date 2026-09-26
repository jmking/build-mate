import Foundation
import Testing

@MainActor
struct ShellTests {
    @Test func projectDiscoveryAndShellActionsPersistWithoutDispatchingBacklog() async throws {
        let f = try await CoreTests.Fixture()
        _ = try await f.runner.run("git", ["remote", "set-url", "origin", "git@github.com:fixture/repo.git"], cwd: f.repo.path)
        _ = try await f.runner.run("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: f.repo.path)
        let discovery = ProjectDiscovery(runner: f.runner)
        try f.marker("missing-gh")
        let missing = try await discovery.inspect(path: f.repo.path)
        #expect(missing.status == "GitHub CLI is not installed" && !missing.authenticated)
        #expect(missing.setupCommand == "brew install gh && gh auth login")
        try FileManager.default.removeItem(at: f.control.appending(path: "missing-gh"))
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
        let model = AppModel(store: uiStore, runner: f.runner)
        try model.add(discovered)
        await model.refresh()
        #expect(model.selectedProject?.id == discovered.project.id)
        do { try model.add(discovered); Issue.record("Duplicate clone accepted") } catch {}
        try await model.createTask(projectID: discovered.project.id, title: "  Make output readable  ", description: "Keep it compact", start: false)
        await model.refresh()
        let task = try #require(model.selectedTask)
        #expect(task.state == .backlog && task.title == "Make output readable")
        #expect(task.worktreePath == nil)
        // A new project's missing recording setup must not consume an agent run through either entry point.
        do { try await model.createTask(projectID: discovered.project.id, title: "Must not start", description: "", start: true); Issue.record("Unconfigured task started") } catch {}
        do { try await model.moveToTodo(task); Issue.record("Unconfigured task moved to Todo") } catch {}
        #expect(try uiStore.all(WorkTask.self).count == 1)
        let legacy = try uiStore.createTask(projectId: discovered.project.id, title: "Previously queued", state: .todo)
        settings.paused = false; try uiStore.saveSettings(settings)
        await model.core.tick()
        #expect(try uiStore.get(WorkTask.self, legacy.id).worktreePath == nil)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "calls.jsonl").path))
        #expect(try await model.core.steer(legacy.id, text: "For the next run") == .saved)
        settings.paused = true; try uiStore.saveSettings(settings)
        var configured = discovered.project; configured.settings.recordingCommand = "true"
        try uiStore.save(configured)
        try await model.moveToTodo(task)
        #expect(try uiStore.get(WorkTask.self, task.id).state == .todo)
        #expect(try uiStore.get(WorkTask.self, task.id).worktreePath == nil)
        try await model.core.deleteTask(legacy.id)
        let session = try uiStore.session(for: task.id)
        try uiStore.save(Message(sessionId: session.id, role: "agent", body: "A persisted transcript"))
        await model.refresh()
        #expect(model.snapshot.messages.contains { $0.body == "A persisted transcript" })
        let restored = AppModel(store: uiStore, runner: f.runner)
        let observer = Task { await restored.observe() }
        let deadline = Date().addingTimeInterval(5)
        while restored.selectedTask?.id != task.id && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(restored.selectedTask?.id == task.id)
        observer.cancel(); await observer.value; await restored.core.shutdown()
        #expect(restored.snapshot.messages.contains { $0.body == "A persisted transcript" })
        // Description-only creation gets a model title; failures and cancellation must not lose the brief or start work.
        let brief = "Please improve our CLI so verbose output is compact and easy to scan. Keep errors visible."
        try await model.createTask(projectID: configured.id, title: "  ", description: brief, start: false)
        await model.refresh()
        let generated = try #require(model.selectedTask)
        #expect(generated.title == "Keep command output compact" && generated.description == brief)
        #expect(generated.state == .backlog && generated.worktreePath == nil)
        #expect(try uiStore.all(Session.self).allSatisfy { $0.ownerId != generated.id })
        try model.renameTask(generated.id, title: "  Keep errors visible in compact output  ")
        let renamed = try uiStore.get(WorkTask.self, generated.id)
        #expect(renamed.title == "Keep errors visible in compact output" && renamed.description == brief && renamed.state == .backlog)
        try f.marker("title-failure")
        try await model.createTask(projectID: configured.id, title: "", description: "Keep errors visible. More detail here.", start: false)
        await model.refresh()
        #expect(model.selectedTask?.title == "Keep errors visible")
        try FileManager.default.removeItem(at: f.control.appending(path: "title-failure"))
        let count = try uiStore.all(WorkTask.self).count
        try f.marker("title-stall")
        let creation = Task { try await model.createTask(projectID: configured.id, title: "", description: "Canceled brief", start: false) }
        let calls = f.control.appending(path: "calls.jsonl")
        let cancellationDeadline = Date().addingTimeInterval(5)
        while !(try String(contentsOf: calls, encoding: .utf8)).contains("Canceled brief") && Date() < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: calls, encoding: .utf8).contains("Canceled brief"))
        creation.cancel()
        do { try await creation.value; Issue.record("Canceled task was created") } catch is CancellationError { }
        #expect(try uiStore.all(WorkTask.self).count == count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: uiStore.root.appending(path: "title-drafts").path).isEmpty)
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
