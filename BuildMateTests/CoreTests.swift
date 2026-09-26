import Foundation
import Testing

@Suite(.serialized)
struct CoreTests {
    struct Fixture {
        let root: URL
        let repo: URL
        let remote: URL
        let control: URL
        let runner: ProcessRunner
        let store: Store
        var project: Project

        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "BuildMateTests-\(UUID())")
            repo = root.appending(path: "user-clone")
            remote = root.appending(path: "remote.git")
            control = root.appending(path: "control")
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            let fixtures = Bundle(for: BundleMarker.self).resourceURL!.appending(path: "Fixtures")
            let bin = root.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["codex", "gh", "twg", "preview"] {
                let destination = bin.appending(path: name)
                try FileManager.default.copyItem(at: fixtures.appending(path: name), to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            for name in ["proof.mp4", "proof.png"] { try FileManager.default.copyItem(at: fixtures.appending(path: name), to: control.appending(path: name)) }
            // Isolated environment: no auth, config, credentials, or real host tools on PATH.
            runner = ProcessRunner(environment: ["PATH": bin.path + ":/usr/bin:/bin", "HOME": root.path,
                                                 "BUILD_MATE_FIXTURE": control.path,
                                                 "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"])
            _ = try await runner.run("git", ["init", "--bare", "--initial-branch=main", remote.path])
            _ = try await runner.run("git", ["clone", remote.path, repo.path])
            try "seed\n".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
            _ = try await runner.run("git", ["add", "README.md"], cwd: repo.path)
            _ = try await runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Seed"], cwd: repo.path)
            _ = try await runner.run("git", ["push", "origin", "main"], cwd: repo.path)
            store = try Store(root: root.appending(path: "Application Support/Build Mate"))
            project = Project(name: "Fixture", repoPath: repo.path, remoteSlug: "fixture/repo")
            project.settings.recordingCommand = "cp \"$BUILD_MATE_FIXTURE/proof.mp4\" \"$BUILD_MATE_RECORDING_PATH\""
            project.settings.checks = [CheckDefinition(name: "Feature exists", command: "test -f feature.txt")]
            project.settings.hooks.afterCreate = "echo create >> \"$BUILD_MATE_FIXTURE/hooks\""
            project.settings.hooks.beforeRun = "echo before >> \"$BUILD_MATE_FIXTURE/hooks\""
            project.settings.hooks.afterRun = "echo after >> \"$BUILD_MATE_FIXTURE/hooks\""
            project.settings.hooks.beforeRemove = "echo remove >> \"$BUILD_MATE_FIXTURE/hooks\""
            try store.save(project)
        }
        func marker(_ name: String) throws { try Data().write(to: control.appending(path: name)) }
        func wait(_ description: String, until predicate: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !(try predicate()) {
                guard ContinuousClock.now < deadline else { throw CoreError.invalid("Timed out: \(description)") }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        func cleanup() throws { try FileManager.default.removeItem(at: root) }
    }

    @Test func lifecycleKeepsCloneCleanGatesProofAndFinishesOnlyAfterMerge() async throws {
        var f = try await Fixture()
        f.project.settings.askBeforeBuild = false
        f.project.settings.stallTimeoutMs = 750
        f.project.settings.recordingCommand = nil
        f.project.settings.checks.append(CheckDefinition(name: "Required proof", command: "test -f \"$BUILD_MATE_FIXTURE/proof-repaired\""))
        try f.store.save(f.project)
        let core = Orchestrator(store: f.store, runner: f.runner)
        let task = try f.store.createTask(projectId: f.project.id, title: "Add plain output", state: .todo, proofRequirement: .checksAndRecording, askBeforeBuild: true)
        #expect(task.state == .todo)
        await core.tick()
        try await f.wait("blocking question") { try f.store.get(WorkTask.self, task.id).state == .needsClarification }
        #expect(try await core.steer(task.id, text: "Keep the output compact") == .sent)
        let question = try #require(f.store.all(Question.self).first)
        let thread = try #require(f.store.session(for: task.id).codexThreadId)
        // A human may take longer than the stall window; answering must still resume.
        try await Task.sleep(for: .seconds(1))
        #expect(question.suggestedAnswer == "Plain")
        try await core.answer(question.id, text: "Plain", useSuggested: true)
        #expect(try f.store.get(Question.self, question.id).answeredBy == "agentDefault")
        try await f.wait("plan approval") { try !f.store.all(Approval.self).isEmpty }
        #expect(try f.store.get(WorkTask.self, task.id).state == .todo)
        try await core.approvePlan(f.store.all(Approval.self)[0].id)
        try await f.wait("human review") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.session(for: task.id).codexThreadId == thread)
        let proof = try #require(f.store.all(Proof.self).first)
        #expect(proof.complete && proof.checks.allSatisfy { $0.status == "passed" })
        #expect(proof.recordingRequired && proof.recordingDuration != nil)
        #expect(try f.store.all(Message.self).filter { $0.kind == "proof" }.count == 2) // Missing and invalid video cannot bypass the user's recording requirement.
        #expect(try f.store.all(Message.self).contains { $0.kind == "proof" }) // Failed proof reached the agent before review.
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "pr-created").path))
        // Editing reviewed work must invalidate proof and the approved plan before the same thread resumes.
        let originalBranch = try f.store.get(WorkTask.self, task.id).branchName
        try await core.editTask(task.id, title: "Improve plain output", description: "Preserve errors in the compact output", proofRequirement: .checksAndRecording)
        let edited = try f.store.get(WorkTask.self, task.id)
        #expect(edited.state == .todo && edited.paused && edited.branchName == originalBranch)
        #expect(try f.store.all(Proof.self).allSatisfy { !$0.complete })
        #expect(try f.store.all(Approval.self).allSatisfy { $0.status == "superseded" })
        do { try await core.openPullRequest(task.id); Issue.record("Edited work bypassed fresh proof") } catch {}
        try await core.pause(task.id, paused: false)
        try await f.wait("fresh plan after edit") { try f.store.all(Approval.self).contains { $0.status == "pending" } }
        let freshPlan = try #require(f.store.all(Approval.self).first { $0.status == "pending" })
        try await core.approvePlan(freshPlan.id)
        try await f.wait("fresh proof after edit") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.session(for: task.id).codexThreadId == thread)
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("Preserve errors in the compact output"))
        // Send Back preserves context and pause, and a changed reviewed commit cannot be published.
        do { try await core.sendBack(task.id, note: "  "); Issue.record("Accepted empty feedback") } catch {}
        let worktree = try #require(f.store.get(WorkTask.self, task.id).worktreePath)
        #expect(try f.store.all(Proof.self).first?.changes.map(\.path) == ["feature.txt"])
        _ = try await f.runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Changed after review"], cwd: worktree)
        do { try await core.openPullRequest(task.id); Issue.record("Published a commit without proof") } catch {}
        try await core.pause(task.id, paused: true)
        try await core.sendBack(task.id, note: "Please verify the revised commit")
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        #expect(try f.store.get(WorkTask.self, task.id).paused)
        #expect(try f.store.all(Proof.self).allSatisfy { !$0.complete })
        try await core.pause(task.id, paused: false)
        try await f.wait("fresh proof after send back") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.session(for: task.id).codexThreadId == thread)
        #expect(try f.store.all(Approval.self).filter { $0.status == "approved" }.count == 1)
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("Please verify the revised commit"))
        await core.shutdown()

        // Reopen SQLite and the orchestrator at the human-review boundary.
        let reopened = try Store(root: f.store.root)
        let resumed = Orchestrator(store: reopened, runner: f.runner)
        try await resumed.recover()
        try await resumed.openPullRequest(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        do { try await resumed.editTask(task.id, title: "Changed scope", description: "Different work", proofRequirement: .checksOnly); Issue.record("PR task scope edited") } catch {}
        try await resumed.editTask(task.id, title: "Clear plain output", description: edited.description, proofRequirement: edited.proofRequirement)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        #expect(try reopened.get(WorkTask.self, task.id).branchName == originalBranch)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        let branch = try #require(reopened.get(WorkTask.self, task.id).branchName)
        // Simulate the host merge in the real bare remote; no network host exists in this test.
        _ = try await f.runner.run("git", ["--git-dir", f.remote.path, "update-ref", "refs/heads/main", "refs/heads/" + branch])
        try f.marker("merged")
        let mergedPath = try #require(reopened.get(WorkTask.self, task.id).worktreePath)
        let unsaved = URL(fileURLWithPath: mergedPath).appending(path: "unsaved.txt")
        try "Preserve this local work".write(to: unsaved, atomically: true, encoding: .utf8)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .done)
        #expect(try reopened.get(WorkTask.self, task.id).doneAt != nil)
        #expect(FileManager.default.fileExists(atPath: unsaved.path)) // A merge must never force-delete uncommitted work.
        try FileManager.default.removeItem(at: unsaved)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).worktreePath == nil)
        #expect(!FileManager.default.fileExists(atPath: mergedPath))
        #expect(await resumed.lastError == nil)
        #expect(try reopened.all(Proof.self).contains { $0.taskId == task.id })
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.repo.path)) == Set([".git", "README.md"]))
        #expect(try String(contentsOf: f.control.appending(path: "pr-body"), encoding: .utf8) == "Adds the requested feature.")
        #expect(FileManager.default.fileExists(atPath: f.store.root.appending(path: "projects/\(f.project.id)/WORKFLOW.md").path))
        try await resumed.deleteProject(f.project.id)
        #expect(try reopened.all(Project.self).isEmpty)
        #expect(try String(contentsOf: f.control.appending(path: "hooks"), encoding: .utf8).contains("remove"))
        #expect(FileManager.default.fileExists(atPath: f.repo.path))
        await resumed.shutdown()
        try f.cleanup()
    }

    @Test func taskProofUsesAgentAssessmentAndHonorsChecksOnlyOverride() async throws {
        for (requirement, visual) in [(ProofRequirement.automatic, false), (.automatic, true), (.checksOnly, true)] {
            var f = try await Fixture()
            f.project.settings.checks = []
            f.project.settings.recordingCommand = nil
            try f.store.save(f.project)
            if visual { try f.marker("visual-task") }
            else { try f.marker("legacy-review"); try f.marker("omit-checks") } // Resumed threads with summary-only tools can submit the same proof report.
            let task = try f.store.createTask(projectId: f.project.id, title: "Task-specific proof", state: .todo, proofRequirement: requirement)
            let core = Orchestrator(store: f.store, runner: f.runner)
            await core.tick()
            try await f.wait("question") { try !f.store.all(Question.self).isEmpty }
            if !visual {
                try await core.editTask(task.id, title: task.title, description: "Updated functional task brief", proofRequirement: requirement)
                #expect(try f.store.get(WorkTask.self, task.id).paused)
                #expect(try f.store.all(Question.self).allSatisfy { $0.answeredBy == "taskEdit" })
                try await core.pause(task.id, paused: false)
                try await f.wait("new question after edit") { try f.store.all(Question.self).contains { $0.answer == nil } }
            }
            let question = try #require(f.store.all(Question.self).first { $0.answer == nil })
            try await core.answer(question.id, text: "Plain")
            try await f.wait("task-specific proof") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
            let proof = try #require(f.store.all(Proof.self).first)
            #expect(proof.complete && proof.checks.count == (visual && requirement != .checksOnly ? 2 : 1) && proof.checks.allSatisfy { $0.status == "passed" })
            #expect(proof.rationale != nil)
            #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "forbidden-write").path))
            let recording = visual && requirement != .checksOnly
            #expect(proof.recordingRequired == recording)
            #expect(proof.screenshots.count == (recording ? 2 : 0))
            #expect((proof.recordingPath != nil) == recording)
            #expect(try f.store.all(Message.self).filter { $0.kind == "proof" }.count == (recording ? 2 : visual ? 0 : 1))
            if !visual {
                try f.marker("always-fail-proof")
                try await core.sendBack(task.id, note: "Exercise failed proof recovery")
                try await f.wait("three failures pause work") { try f.store.get(WorkTask.self, task.id).paused && f.store.all(RunAttempt.self).last?.endedAt != nil }
                #expect(try f.store.get(WorkTask.self, task.id).retry?.error.contains("three times") == true)
                #expect(try f.store.get(WorkTask.self, task.id).state == .building)
                try FileManager.default.removeItem(at: f.control.appending(path: "always-fail-proof"))
                try await core.pause(task.id, paused: false)
                try await f.wait("resume after failed proof") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
            }
            await core.shutdown()
            try f.cleanup()
        }
    }

    // Catches port collisions, orphan preview children, and bypasses of the shared heavy-work limit.
    @Test func previewsUseSeparateWorktreesAndReleasePortsOnStopFailureAndQuit() async throws {
        var f = try await Fixture()
        f.project.paused = true
        f.project.settings.previewCommand = "preview"
        f.project.settings.previewPortEnvVar = "CUSTOM_PORT"
        f.project.settings.previewReadyPath = "/health"
        try f.store.save(f.project)
        let workspace = Workspace(store: f.store, runner: f.runner)
        var preparedTasks: [WorkTask] = []
        for title in ["First preview", "Second preview", "Waiting preview"] {
            let task = try f.store.createTask(projectId: f.project.id, title: title, state: .todo)
            preparedTasks.append(try await workspace.prepare(task, project: f.project))
        }
        let core = Orchestrator(store: f.store, runner: f.runner)
        let tasks = preparedTasks
        async let first = core.startPreview(tasks[0].id, timeout: 5)
        async let second = core.startPreview(tasks[1].id, timeout: 5)
        async let duplicate = core.startPreview(tasks[0].id, timeout: 5)
        let urls = try await [first, second]
        #expect(try await duplicate == urls[0])
        #expect(urls[0].port != urls[1].port && urls.allSatisfy { $0.host == "127.0.0.1" && $0.path == "/" })
        for (index, url) in urls.enumerated() {
            let (data, _) = try await URLSession.shared.data(from: url)
            #expect(String(decoding: data, as: UTF8.self) == String(tasks[index].number))
        }
        #expect(try await core.startPreview(tasks[0].id) == urls[0])
        do { _ = try await core.startPreview(tasks[2].id); Issue.record("Exceeded preview slot limit") } catch {}
        await core.stopPreview(tasks[0].id)
        #expect(await core.previews[tasks[0].id] == nil)
        do { _ = try await URLSession.shared.data(from: urls[0]); Issue.record("Stopped preview still serves HTTP") } catch {}
        f.project.settings.previewCommand = "preview --never-ready"
        try f.store.save(f.project)
        do { _ = try await core.startPreview(tasks[2].id, timeout: 0.5); Issue.record("Unready preview was accepted") } catch {}
        #expect(await core.previews[tasks[2].id]?.phase == "failed")
        #expect(await core.heavySteps == 1)
        f.project.settings.previewCommand = "echo startup-failed; exit 7"
        try f.store.save(f.project)
        do { _ = try await core.startPreview(tasks[2].id, timeout: 2); Issue.record("Exited preview was accepted") } catch {}
        #expect(await core.previews[tasks[2].id]?.log.contains("startup-failed") == true)
        f.project.settings.previewCommand = "preview --never-ready"
        try f.store.save(f.project)
        let pending = Task { try await core.startPreview(tasks[2].id, timeout: 5) }
        for _ in 0..<100 {
            if await core.previews[tasks[2].id]?.phase == "starting" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await core.stopPreview(tasks[2].id)
        do { _ = try await pending.value; Issue.record("Stopped startup completed") } catch {}
        #expect(await core.heavySteps == 1)
        await core.shutdown()
        #expect(await core.previews.isEmpty)
        #expect(await core.heavySteps == 0)
        do { _ = try await URLSession.shared.data(from: urls[1]); Issue.record("Quit left preview running") } catch {}
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        try f.cleanup()
    }

    @Test func schedulerRespectsRankDependenciesPauseAndResumesThreadAfterCrash() async throws {
        var f = try await Fixture()
        f.project.settings.stallTimeoutMs = 500
        try f.store.save(f.project)
        var settings = AppSettings(); settings.agentsAtOnce = 1; try f.store.saveSettings(settings)
        let backlog = try f.store.createTask(projectId: f.project.id, title: "Never dispatch", rank: 100)
        let dependency = try f.store.createTask(projectId: f.project.id, title: "Blocked", state: .todo, rank: 90, dependsOn: [backlog.id])
        let high = try f.store.createTask(projectId: f.project.id, title: "First", state: .todo, rank: 10)
        let low = try f.store.createTask(projectId: f.project.id, title: "Second", state: .todo, rank: 20)
        let ordering = await AppModel(store: f.store, runner: f.runner)
        try await ordering.reorderTask(high.id, relativeTo: low.id, after: false) // The next dispatch follows the user’s reordered queue.
        try f.marker("crash-once")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("retry after process exit") { try f.store.get(WorkTask.self, high.id).retry != nil }
        let first = try f.store.get(WorkTask.self, high.id)
        #expect(try f.store.get(WorkTask.self, low.id).worktreePath == nil)
        #expect(try f.store.get(WorkTask.self, dependency.id).worktreePath == nil)
        #expect(try f.store.get(WorkTask.self, backlog.id).worktreePath == nil)
        #expect(first.retry!.dueAt.timeIntervalSince(first.createdAt) >= 10)
        let thread = try #require(f.store.session(for: high.id).codexThreadId)
        // Hold other candidates so the retry deadline is observable at the process boundary.
        try await core.pause(low.id, paused: true)
        await core.tick()
        #expect(try f.store.session(for: high.id).turnCount == 1)
        await core.shutdown()

        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        try await resumed.recover()
        try f.marker("stall")
        await resumed.tick(now: first.retry!.dueAt.addingTimeInterval(1))
        try await f.wait("stall retry and cleanup") {
            try f.store.get(WorkTask.self, high.id).retry?.attempt == 2 && f.store.all(RunAttempt.self).contains { $0.status == "stalled" }
        }
        // Observe the reopened store without starting a competing get-or-create write transaction.
        #expect(try f.store.all(Session.self).first { $0.ownerId == high.id }?.codexThreadId == thread)
        #expect(try f.store.all(RunAttempt.self).contains { $0.status == "stalled" })
        try FileManager.default.removeItem(at: f.control.appending(path: "stall"))
        let second = try f.store.get(WorkTask.self, high.id)
        await resumed.shutdown()
        let third = Orchestrator(store: f.store, runner: f.runner)
        await third.tick(now: second.retry!.dueAt.addingTimeInterval(1))
        try await f.wait("question on resumed thread") { try f.store.get(WorkTask.self, high.id).state == .needsClarification }
        // A question waiting in a live process still reserves the sole concurrency slot.
        var available = try f.store.get(WorkTask.self, low.id); available.paused = false; try f.store.save(available)
        await third.tick()
        #expect(try f.store.get(WorkTask.self, low.id).worktreePath == nil)
        try await third.pause(high.id, paused: true)
        await third.shutdown()
        #expect(try f.store.get(WorkTask.self, high.id).paused)
        #expect(FileManager.default.fileExists(atPath: first.worktreePath!))
        let calls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)
        #expect(calls.contains("thread/resume"))
        #expect(calls.contains("turn/interrupt"))
        let hooks = try String(contentsOf: f.control.appending(path: "hooks"), encoding: .utf8).split(separator: "\n")
        #expect(hooks.filter { $0 == "create" }.count == 1)
        #expect(hooks.filter { $0 == "before" }.count == hooks.filter { $0 == "after" }.count)
        try f.cleanup()
    }

    @Test func failedWorkspaceHookRetriesAndTimedOutHookKillsItsChildren() async throws {
        var f = try await Fixture()
        f.project.settings.hooks.afterCreate = "if test ! -f \"$BUILD_MATE_FIXTURE/created-once\"; then touch \"$BUILD_MATE_FIXTURE/created-once\"; exit 9; fi"
        f.project.settings.hooks.beforeRun = "(sleep 0.5; touch \"$BUILD_MATE_FIXTURE/orphan-wrote\") & wait"
        f.project.settings.hooks.timeoutSeconds = 0.1
        try f.store.save(f.project)
        let task = try f.store.createTask(projectId: f.project.id, title: "Hook recovery", state: .todo)
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("failed create hook cleanup") {
            try f.store.get(WorkTask.self, task.id).retry?.attempt == 1 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        let first = try f.store.get(WorkTask.self, task.id)
        #expect(!first.workspaceReady)
        #expect(try f.store.session(for: task.id).codexThreadId == nil)
        await core.shutdown()
        let retry = Orchestrator(store: f.store, runner: f.runner)
        await retry.tick(now: first.retry!.dueAt.addingTimeInterval(1))
        try await f.wait("timed out before-run hook cleanup") {
            try f.store.get(WorkTask.self, task.id).retry?.attempt == 2 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "orphan-wrote").path))
        #expect(try f.store.get(WorkTask.self, task.id).workspaceReady)
        #expect(try f.store.get(WorkTask.self, task.id).worktreePath == first.worktreePath)
        #expect(try f.store.all(RunAttempt.self).contains { $0.status == "timedOut" })
        await retry.shutdown()
        f.project.settings.hooks.beforeRun = ""
        f.project.settings.turnTimeoutMs = 250
        f.project.settings.stallTimeoutMs = 0 // Explicitly disabled, not an instant stall.
        try f.store.save(f.project)
        try f.marker("flood")
        let flood = Orchestrator(store: f.store, runner: f.runner)
        let due = try f.store.get(WorkTask.self, task.id).retry!.dueAt
        await flood.tick(now: due.addingTimeInterval(1))
        try await f.wait("turn deadline despite continuous events") {
            try f.store.get(WorkTask.self, task.id).retry?.attempt == 3 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        #expect(try f.store.get(WorkTask.self, task.id).retry!.error.contains("turn timed out"))
        await flood.shutdown()
        let worktrees = f.store.root.appending(path: "worktrees")
        try FileManager.default.moveItem(at: worktrees, to: f.store.root.appending(path: "retained-worktrees"))
        try FileManager.default.createSymbolicLink(at: worktrees, withDestinationURL: f.repo)
        let escaped = Orchestrator(store: f.store, runner: f.runner)
        await escaped.tick(now: Date().addingTimeInterval(400))
        try await f.wait("reject escaped root before any hook or git mutation") {
            try f.store.get(WorkTask.self, task.id).retry?.attempt == 4 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        #expect(try f.store.get(WorkTask.self, task.id).retry!.error.contains("outside Build Mate storage"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.repo.path)) == Set([".git", "README.md"]))
        await escaped.shutdown()
        try f.cleanup()
    }

    @Test func transitionRulesRejectSkippingProofQuestionsPlanDependenciesOrMerge() throws {
        let allowed: [TaskState: Set<TaskState>] = [
            .backlog: [.todo, .backlog, .canceled],
            .todo: [.backlog, .needsClarification, .building, .canceled],
            .needsClarification: [.backlog, .todo, .building, .canceled],
            .building: [.backlog, .needsClarification, .humanReview, .canceled],
            .humanReview: [.backlog, .building, .inPR, .canceled],
            .inPR: [.done, .canceled], .done: [], .canceled: []
        ]
        for from in TaskState.allCases {
            for to in TaskState.allCases {
                let valid = (try? TransitionRules.validate(from: from, to: to, proofComplete: true, merged: true)) != nil
                #expect(valid == allowed[from, default: []].contains(to), "\(from) → \(to)")
            }
        }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .building, to: .humanReview) }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .humanReview, to: .inPR) }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .needsClarification, to: .building, questionsAnswered: false) }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .todo, to: .building, planApproved: false) }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .todo, to: .building, dependenciesReady: false) }
        #expect(throws: CoreError.self) { try TransitionRules.validate(from: .inPR, to: .done) }
    }
}
private final class BundleMarker: NSObject {}
