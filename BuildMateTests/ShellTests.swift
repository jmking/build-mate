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
        try await model.createTask(projectID: project.id, title: "First local feature", description: "Implement and check a functional change")
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

    // Catch inverted percentages, selecting a different product's bucket, stale failures and accidental agent starts.
    @Test func usageReadsAccountWindowsWithoutStartingTasksAndPreservesUnknownValues() async throws {
        let f = try await CoreTests.Fixture()
        let model = AppModel(store: f.store, runner: f.runner)
        let file = f.control.appending(path: "usage.json")
        try #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitName":"Codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1790440000},"secondary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1790500000}},"other":{"primary":{"usedPercent":98}}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage(); await model.refresh()
        #expect(model.usage.windows.count == 3)
        #expect(model.usage.limitingWindow?.remaining == 19)
        #expect(model.usage.limitingWindow?.duration == "7-day window")
        #expect(model.usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1790440000))
        try f.marker("usage-error")
        await model.core.refreshUsage(); await model.refresh()
        #expect(model.usage.error != nil && model.usage.limitingWindow?.remaining == 19)
        try FileManager.default.removeItem(at: f.control.appending(path: "usage-error"))
        try #"{"rateLimits":{"primary":{"usedPercent":90},"secondary":null}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage(); await model.refresh()
        #expect(model.usage.error == nil && model.usage.limitingWindow?.remaining == 10)
        #expect(model.usage.limitingWindow?.resetsAt == nil)
        try #"{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":null}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage(); await model.refresh()
        #expect(model.usage.windows.isEmpty)
        let calls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)
        #expect(!calls.contains("thread/start") && !calls.contains("turn/start"))
        #expect(try f.store.all(Session.self).isEmpty)
        // Old settings must load with the new hold default; low usage must gate real dispatch, not just its label.
        try await f.store.db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO appSettings VALUES (1, ?)", arguments: [Data(#"{"agentsAtOnce":1,"heavyStepsAtOnce":1,"instructions":"legacy","paused":false}"#.utf8)])
        }
        #expect(try f.store.settings().usageHoldThreshold == 15)
        try #"{"rateLimits":{"primary":{"usedPercent":95}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage()
        var slowReadProject = try f.store.get(Project.self, f.project.id)
        slowReadProject.settings.readTimeoutMs = 60_000; try f.store.save(slowReadProject)
        let queued = try f.store.createTask(projectId: f.project.id, title: "Wait for usage", state: .todo)
        await model.core.tick(); await model.refresh()
        #expect(model.usageHeld)
        #expect(try f.store.all(RunAttempt.self).isEmpty)
        try f.marker("usage-error"); await model.core.refreshUsage(); await model.core.tick()
        #expect(await model.core.usageHeld()) // A failed refresh must not silently lift a known hold.
        try FileManager.default.removeItem(at: f.control.appending(path: "usage-error"))
        // Exhausted included usage must still dispatch with credits, without a manual override.
        let credited = #"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100},"credits":{"hasCredits":true,"unlimited":false,"balance":"2034.1956750000"},"spendControlReached":false,"rateLimitReachedType":"rate_limit_reached"}}"#
        try credited.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage(); await model.refresh()
        #expect(!model.usageHeld && model.usage.credits?.balance == Decimal(string: "2034.1956750000"))
        var snapshot = model.usage
        snapshot.apply(.codex(try JSONDecoder().decode(JSON.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":100}}}"#.utf8)), replacing: false))
        #expect(snapshot.canUseCredits) // Sparse notifications must not discard the last credit balance.
        snapshot.apply(.codex(try JSONDecoder().decode(JSON.self, from: Data(#"{"rateLimits":{"credits":null}}"#.utf8)), replacing: false))
        #expect(!snapshot.canUseCredits)
        #expect(snapshot.limitingWindow?.remaining == 0) // A credit-only update cannot clear an exhausted window.
        await model.core.tick()
        let usageStore = f.store
        try await f.wait("credit-backed dispatch") { @Sendable in try usageStore.all(Question.self).contains { $0.taskId == queued.id } }
        for (creditJSON, held) in [
            (#"{"primary":{"usedPercent":100},"credits":{"hasCredits":true,"unlimited":true,"balance":null}}"#, false),
            (#"{"primary":{"usedPercent":100},"credits":{"hasCredits":true,"unlimited":false,"balance":"20"},"spendControlReached":true}"#, true),
            (#"{"primary":{"usedPercent":100},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}"#, true)
        ] {
            try ("{\"rateLimits\":" + creditJSON + "}").write(to: file, atomically: true, encoding: .utf8)
            await model.core.refreshUsage()
            #expect(await model.core.usageHeld() == held)
        }
        // A different product's credits must not release a Codex hold.
        try #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100}},"other":{"credits":{"hasCredits":true,"unlimited":true}}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage()
        #expect(await model.core.usageHeld())
        await model.core.resumeDespiteUsage()
        await model.refresh()
        let attention = model.attentionItems.map(\.id)
        #expect(attention.count == 1)
        await model.refresh(); #expect(model.attentionItems.map(\.id) == attention)
        #expect(!model.usageHeld)
        let thread = try f.store.session(for: queued.id).providerSessionID
        try f.marker("ignore-interrupt")
        let pauseStarted = Date()
        try model.pauseAll(); await model.core.tick()
        try await f.wait("bounded pause with unresponsive interrupt") { @Sendable in try usageStore.session(for: queued.id).status == "idle" }
        #expect(Date().timeIntervalSince(pauseStarted) < 30)
        #expect(try f.store.session(for: queued.id).providerSessionID == thread)
        try #"{"rateLimits":{"primary":{"usedPercent":10}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage()
        try #"{"rateLimits":{"primary":{"usedPercent":95}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await model.core.refreshUsage()
        #expect(await model.core.usageHeld()) // Recovery resets the one-time override.
        await model.core.shutdown()
        try f.cleanup()
    }

    @Test func projectDiscoveryAndQueuedTasksPersistWithoutDispatchingWhilePaused() async throws {
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
        try await model.createTask(projectID: discovered.project.id, title: "  Make output readable  ", description: "Keep it compact", files: [f.control.appending(path: "proof.mp4")])
        await model.refresh()
        let task = try #require(model.selectedTask)
        #expect(task.state == .todo && task.title == "Make output readable")
        #expect(task.worktreePath == nil)
        try await model.editTask(task.id, title: "Keep errors readable", description: "Compact output, with full error details", proofRequirement: .checksOnly)
        _ = try await model.core.models()
        try await model.editTask(task.id, title: "Keep errors readable", description: "Compact output, with full error details", proofRequirement: .checksOnly,
                                 configuration: AgentConfiguration(id: task.id, model: "gpt-6-astra", effort: "high"))
        #expect(try uiStore.get(AgentConfiguration.self, task.id).model == "gpt-6-astra")
        do {
            try await model.editTask(task.id, title: "Must not save", description: "Must not save", proofRequirement: .automatic,
                                     configuration: AgentConfiguration(id: task.id, model: "gpt-5.6-luna", effort: "ultra"))
            Issue.record("Saved an edit with an unsupported model/effort")
        } catch {}
        let edited = try uiStore.get(WorkTask.self, task.id)
        #expect(edited.title == "Keep errors readable" && edited.description == "Compact output, with full error details" && edited.proofRequirement == .checksOnly)
        #expect(edited.state == .todo && !edited.paused && edited.worktreePath == nil)
        #expect(try uiStore.all(Session.self).isEmpty) // Editing a draft must not create or dispatch an agent session.
        do { try await model.editTask(task.id, title: "  ", description: "Lost draft", proofRequirement: .automatic); Issue.record("Empty title accepted") } catch {}
        #expect(try uiStore.get(WorkTask.self, task.id).description == edited.description)
        let video = try #require(uiStore.all(Attachment.self).first)
        #expect(video.kind == "video" && video.frames.count == 6)
        #expect(JSON.codexInput("Review", attachments: [video]).array.filter { $0["type"].string == "localImage" }.count == 6)
        let other = try uiStore.createTask(projectId: discovered.project.id, title: "Other queued task", rank: 10)
        try model.reorderTask(task.id, relativeTo: other.id, after: false)
        await model.refresh()
        #expect(model.tasks(discovered.project.id).first?.id == task.id)
        try model.reorderTask(task.id, relativeTo: other.id, after: true)
        await model.refresh()
        #expect(model.tasks(discovered.project.id).first?.id == other.id)
        #expect(try uiStore.get(WorkTask.self, task.id).state == .todo)
        // Hover is only a preview: refresh preserves it, cancellation never writes ranks,
        // and a successful drop publishes and persists the final order without a flash.
        let originalRank = try uiStore.get(WorkTask.self, task.id).rank
        model.beginPriorityDrag(task)
        model.previewPriorityDrag(over: other, after: false)
        #expect(model.tasks(discovered.project.id).first?.id == task.id)
        #expect(try uiStore.get(WorkTask.self, task.id).rank == originalRank)
        await model.refresh()
        #expect(model.tasks(discovered.project.id).first?.id == task.id)
        model.finishPriorityDrag(commit: false)
        #expect(model.tasks(discovered.project.id).first?.id == other.id)
        #expect(try uiStore.get(WorkTask.self, task.id).rank == originalRank)
        model.beginPriorityDrag(task)
        model.previewPriorityDrag(over: other, after: false)
        model.finishPriorityDrag(commit: true)
        #expect(model.priorityDrag == nil && model.tasks(discovered.project.id).first?.id == task.id)
        await model.refresh()
        #expect(model.tasks(discovered.project.id).first?.id == task.id)
        try await model.core.deleteTask(other.id)
        // No recording setup is needed to queue functional work; global pause still prevents dispatch.
        try await model.createTask(projectID: discovered.project.id, title: "Functional work", description: "Verify an API", proofRequirement: .checksOnly)
        var started = try #require(uiStore.all(WorkTask.self).first { $0.title == "Functional work" })
        #expect(started.state == .todo && started.proofRequirement == .checksOnly && started.worktreePath == nil)
        started.state = .building; try uiStore.save(started)
        model.beginPriorityDrag(task)
        #expect(!model.canDropPriority(on: started))
        model.previewPriorityDrag(over: started, after: false)
        #expect(model.priorityDrag?.targetID == nil)
        model.finishPriorityDrag(commit: false)
        do { try model.reorderTask(task.id, relativeTo: started.id, after: false); Issue.record("Cross-state reorder accepted") } catch {}
        started.state = .todo; try uiStore.save(started)
        #expect(try await model.core.steer(started.id, text: "For the next run") == .saved)
        #expect(((try? String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)) ?? "").contains("thread/start") == false)
        #expect(try uiStore.get(WorkTask.self, task.id).state == .todo)
        #expect(try uiStore.get(WorkTask.self, task.id).worktreePath == nil)
        try await model.core.deleteTask(started.id)
        model.destination = .task(task.id)
        let session = try uiStore.session(for: task.id)
        try uiStore.save(Message(sessionId: session.id, role: "agent", body: "A persisted transcript"))
        await model.refresh()
        #expect(model.snapshot.messages.contains { $0.body == "A persisted transcript" })
        // Navigation must retain drafts and collection-specific searches without filtering unrelated views.
        model.chatDrafts[task.id] = "A draft to finish after checking the queue"
        model.destination = .project(discovered.project.id, .tasks)
        model.search = "no matching task"
        #expect(model.tasks(discovered.project.id).isEmpty)
        model.destination = .needsYou
        #expect(model.search.isEmpty)
        model.destination = .project(discovered.project.id, .tasks)
        #expect(model.search == "no matching task")
        model.search = ""
        model.destination = .task(task.id)
        #expect(!model.canSearch && model.chatDrafts[task.id] == "A draft to finish after checking the queue")
        model.showInspector = true
        model.setBriefExpanded(task.id, expanded: false)
        model.setProjectExpanded(discovered.project.id, expanded: false)
        let restored = AppModel(store: uiStore, runner: f.runner)
        let observer = Task { await restored.observe() }
        let deadline = Date().addingTimeInterval(5)
        while restored.selectedTask?.id != task.id && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(restored.selectedTask?.id == task.id)
        #expect(restored.showInspector && !restored.isBriefExpanded(task) && !restored.isProjectExpanded(discovered.project.id))
        observer.cancel(); await observer.value; await restored.core.shutdown()
        #expect(restored.snapshot.messages.contains { $0.body == "A persisted transcript" })
        #expect(restored.selectedTask?.description == edited.description && restored.selectedTask?.proofRequirement == .checksOnly)
        // A stalled model must not hold creation open; later naming must never undo a manual edit.
        func waitForNaming() async throws {
            let deadline = Date().addingTimeInterval(5)
            while !(await model.core.titleJobs.isEmpty) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(await model.core.titleJobs.isEmpty)
        }
        let brief = "Please improve our CLI so verbose output is compact and easy to scan. Keep errors visible."
        try await model.createTask(projectID: discovered.project.id, title: "  ", description: brief)
        let generated = try #require(model.selectedTask)
        #expect(generated.title == Orchestrator.provisionalTitle(brief) && generated.description == brief)
        #expect(!model.showNewTask && generated.state == .todo && generated.worktreePath == nil)
        try await waitForNaming()
        #expect(try uiStore.get(WorkTask.self, generated.id).title == "Keep command output compact")
        #expect(try uiStore.all(Session.self).allSatisfy { $0.ownerId != generated.id })
        try await model.editTask(generated.id, title: "  Keep errors visible in compact output  ", description: generated.description, proofRequirement: generated.proofRequirement)
        let renamed = try uiStore.get(WorkTask.self, generated.id)
        #expect(renamed.title == "Keep errors visible in compact output" && renamed.description == brief && renamed.state == .todo)
        try f.marker("title-failure")
        try await model.createTask(projectID: discovered.project.id, title: "", description: "Keep errors visible. More detail here.")
        let fallback = try #require(model.selectedTask)
        try await waitForNaming()
        #expect(try uiStore.get(WorkTask.self, fallback.id).title == "Keep errors visible")
        try FileManager.default.removeItem(at: f.control.appending(path: "title-failure"))
        // No economical model means no title inference, never the expensive project/default model.
        try f.marker("no-cheap-title-model")
        let callsBefore = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).components(separatedBy: "thread/start").count
        try await model.createTask(projectID: discovered.project.id, title: "", description: "Local title when cheap models are unavailable")
        try await waitForNaming()
        #expect(model.selectedTask?.title == "Local title when cheap models are unavailable")
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).components(separatedBy: "thread/start").count == callsBefore)
        try FileManager.default.removeItem(at: f.control.appending(path: "no-cheap-title-model"))
        try f.marker("title-stall")
        let clock = ContinuousClock()
        let began = clock.now
        try await model.createTask(projectID: discovered.project.id, title: "", description: "Instant saved brief")
        let elapsed = began.duration(to: clock.now)
        #expect(elapsed < .seconds(1))
        print("Task creation with stalled naming: \(elapsed)")
        let instant = try #require(model.selectedTask)
        #expect(instant.title == "Instant saved brief" && !model.showNewTask)
        let calls = f.control.appending(path: "calls.jsonl")
        let titleDeadline = Date().addingTimeInterval(5)
        while !(try String(contentsOf: calls, encoding: .utf8)).contains("Instant saved brief") && Date() < titleDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: calls, encoding: .utf8).contains("Instant saved brief"))
        try await model.editTask(instant.id, title: "My authoritative title", description: instant.description, proofRequirement: instant.proofRequirement)
        try await waitForNaming()
        #expect(try uiStore.get(WorkTask.self, instant.id).title == "My authoritative title")
        // Shutdown cancels naming, but the already-created task survives shutdown.
        try await model.createTask(projectID: discovered.project.id, title: "", description: "Keep this saved task")
        let saved = try #require(model.selectedTask)
        await model.core.shutdown()
        #expect(try uiStore.get(WorkTask.self, saved.id).title == "Keep this saved task")
        #expect(try FileManager.default.contentsOfDirectory(atPath: uiStore.root.appending(path: "title-drafts").path).isEmpty)
        _ = try await f.runner.run("git", ["remote", "set-url", "origin", "https://bitbucket.org/team/project.git"], cwd: f.repo.path)
        let bitbucket = try await discovery.inspect(path: f.repo.path)
        #expect(bitbucket.project.host == .bitbucket && !bitbucket.project.paused && bitbucket.authenticated)
        #expect(bitbucket.project.remoteSlug == "team/project")
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        await model.core.shutdown()
        try uiStore.db.close()
        try f.store.db.close()
        try f.cleanup()
    }
}
