import Foundation
import Testing

@MainActor
struct ShellTests {
    @Test func newLocalProjectBuildsInWorktreeWithoutPublishingOrOverwritingFolders() async throws {
        let f = try await CoreTests.Fixture()
        let discovery = ProjectDiscovery(runner: f.runner)
        let folder = f.root.appending(path: "New Project")
        let model = AppModel(store: f.store, runner: f.runner)
        try await model.createProject(path: folder.path)
        let project = try #require(model.selectedProject)
        #expect(project.host == .local && project.name == "New Project" && project.defaultBranch == "main" && !project.paused)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set([".git"]))
        #expect(try await f.runner.run("git", ["remote"], cwd: folder.path).output.isEmpty)
        #expect(try await f.runner.run("git", ["rev-list", "--count", "HEAD"], cwd: folder.path).output.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        let imported = try await discovery.inspect(path: folder.path)
        #expect(imported.project.host == .local && imported.setupCommand == nil)
        do { try model.add(imported); Issue.record("Duplicate local project accepted") } catch {}
        do { _ = try await discovery.create(path: folder.path); Issue.record("Existing repository reinitialized") } catch {}
        let occupied = f.root.appending(path: "Existing files")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "Keep this".write(to: occupied.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        do { _ = try await discovery.create(path: occupied.path); Issue.record("Nonempty folder accepted") } catch {}
        #expect(try String(contentsOf: occupied.appending(path: "notes.txt"), encoding: .utf8) == "Keep this")
        #expect(!FileManager.default.fileExists(atPath: occupied.appending(path: ".git").path))
        let nested = f.repo.appending(path: "nested-project")
        do { _ = try await discovery.create(path: nested.path); Issue.record("Nested repository created") } catch {}
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        let empty = f.root.appending(path: "Empty folder")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try await discovery.create(path: empty.path).project.host == .local)
        try model.pauseProject(project)
        #expect(try f.store.get(Project.self, project.id).paused)
        try model.pauseProject(project)
        try await model.createTask(projectID: project.id, title: "First local feature", description: "Implement and check a functional change", start: true)
        await model.refresh()
        let task = try #require(model.selectedTask)
        let store = f.store
        try await f.wait("local project question") { @Sendable in try !store.all(Question.self).isEmpty }
        try await model.core.answer(f.store.all(Question.self)[0].id, text: "Plain")
        try await f.wait("local project proof") { @Sendable in try store.get(WorkTask.self, task.id).state == .humanReview }
        let built = try f.store.get(WorkTask.self, task.id)
        #expect(built.worktreePath?.hasPrefix(f.store.root.path) == true)
        #expect(FileManager.default.fileExists(atPath: built.worktreePath! + "/feature.txt"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set([".git"]))
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: folder.path).output.isEmpty)
        do { try await model.core.openPullRequest(task.id); Issue.record("Local project tried to publish") } catch {}
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "pr-created").path))
        await model.core.shutdown()
        try f.store.db.close()
        try f.cleanup()
    }

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
        try await model.editTask(task.id, title: "Keep errors readable", description: "Compact output, with full error details", proofRequirement: .checksOnly)
        let edited = try uiStore.get(WorkTask.self, task.id)
        #expect(edited.title == "Keep errors readable" && edited.description == "Compact output, with full error details" && edited.proofRequirement == .checksOnly)
        #expect(edited.state == .backlog && !edited.paused && edited.worktreePath == nil)
        #expect(try uiStore.all(Session.self).isEmpty) // Editing a draft must not create or dispatch an agent session.
        do { try await model.editTask(task.id, title: "  ", description: "Lost draft", proofRequirement: .automatic); Issue.record("Empty title accepted") } catch {}
        #expect(try uiStore.get(WorkTask.self, task.id).description == edited.description)
        // No recording setup is needed to queue functional work; global pause still prevents dispatch.
        try await model.createTask(projectID: discovered.project.id, title: "Functional work", description: "Verify an API", start: true, proofRequirement: .checksOnly)
        let started = try #require(uiStore.all(WorkTask.self).first { $0.title == "Functional work" })
        #expect(started.state == .todo && started.proofRequirement == .checksOnly && started.worktreePath == nil)
        #expect(try await model.core.steer(started.id, text: "For the next run") == .saved)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "calls.jsonl").path))
        try await model.moveToTodo(task)
        #expect(try uiStore.get(WorkTask.self, task.id).state == .todo)
        #expect(try uiStore.get(WorkTask.self, task.id).worktreePath == nil)
        try await model.core.deleteTask(started.id)
        model.destination = .task(task.id)
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
        #expect(restored.selectedTask?.description == edited.description && restored.selectedTask?.proofRequirement == .checksOnly)
        // Description-only creation gets a model title; failures and cancellation must not lose the brief or start work.
        let brief = "Please improve our CLI so verbose output is compact and easy to scan. Keep errors visible."
        try await model.createTask(projectID: discovered.project.id, title: "  ", description: brief, start: false)
        await model.refresh()
        let generated = try #require(model.selectedTask)
        #expect(generated.title == "Keep command output compact" && generated.description == brief)
        #expect(generated.state == .backlog && generated.worktreePath == nil)
        #expect(try uiStore.all(Session.self).allSatisfy { $0.ownerId != generated.id })
        try await model.editTask(generated.id, title: "  Keep errors visible in compact output  ", description: generated.description, proofRequirement: generated.proofRequirement)
        let renamed = try uiStore.get(WorkTask.self, generated.id)
        #expect(renamed.title == "Keep errors visible in compact output" && renamed.description == brief && renamed.state == .backlog)
        try f.marker("title-failure")
        try await model.createTask(projectID: discovered.project.id, title: "", description: "Keep errors visible. More detail here.", start: false)
        await model.refresh()
        #expect(model.selectedTask?.title == "Keep errors visible")
        try FileManager.default.removeItem(at: f.control.appending(path: "title-failure"))
        let count = try uiStore.all(WorkTask.self).count
        try f.marker("title-stall")
        let creation = Task { try await model.createTask(projectID: discovered.project.id, title: "", description: "Canceled brief", start: false) }
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
