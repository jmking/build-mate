import Foundation
import Darwin
import Testing

@Suite(.serialized)
struct CoreTests {
    // Prevent stale dependency bases and publishing an unreviewed branch tip during an editor race.
    @Test func newWorkUsesRemoteBaseAndPublicationPinsReviewedCommitAndRequirements() async throws {
        let f = try await Fixture()
        let other = f.root.appending(path: "other-clone")
        _ = try await f.runner.run("git", ["clone", f.remote.path, other.path])
        try "merged dependency".write(to: other.appending(path: "dependency.txt"), atomically: true, encoding: .utf8)
        _ = try await f.runner.run("git", ["add", "."], cwd: other.path)
        _ = try await f.runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Dependency merged"], cwd: other.path)
        _ = try await f.runner.run("git", ["push", "origin", "main"], cwd: other.path)
        let original = try f.store.createTask(projectId: f.project.id, title: "Next change")
        let task = try await Workspace(store: f.store, runner: f.runner).prepare(original, project: f.project)
        let cwd = try #require(task.worktreePath)
        #expect(FileManager.default.fileExists(atPath: cwd + "/dependency.txt"))
        #expect(!FileManager.default.fileExists(atPath: f.repo.path + "/dependency.txt"))
        try "feature".write(to: URL(fileURLWithPath: cwd).appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        _ = try await f.runner.run("git", ["add", "."], cwd: cwd)
        _ = try await f.runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Feature"], cwd: cwd)
        let core = Orchestrator(store: f.store, runner: f.runner)
        try await core.transition(task.id, to: .building)
        let submission = try ProofSubmission(.object(["summary": .string("Adds the requested feature."), "needsRecording": .bool(false), "rationale": .string("Verify the feature and merged dependency"), "checks": .array([.object(["name": .string("Dependency available"), "command": .string("test -f dependency.txt")])])]))
        var proof = try await ProofRunner(store: f.store, runner: f.runner).run(task: task, project: f.project, submission: submission)
        #expect(proof.complete && proof.changes.map(\.path) == ["feature.txt"])
        try await core.transition(task.id, to: .humanReview)
        proof.requirementsRevision = 0; try f.store.save(proof)
        do { try await core.openPullRequest(task.id); Issue.record("Published superseded requirements") } catch {}
        proof.requirementsRevision = task.requirementsRevision; try f.store.save(proof)
        try f.marker("move-head-during-publish")
        try await core.openPullRequest(task.id)
        let published = try await f.runner.run("git", ["--git-dir", f.remote.path, "rev-parse", "refs/heads/" + task.branchName!]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = try await f.runner.run("git", ["rev-parse", "HEAD"], cwd: cwd).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(published == proof.commitSHA && current != published)
        await core.shutdown()
        try f.cleanup()
    }
    @Test func slowConversationStartDoesNotExhaustAShortResponseTimeout() async throws {
        var f = try await Fixture()
        f.project.settings.readTimeoutMs = 1_000; try f.store.save(f.project) // Shorter than the 2 s cold start below.
        try f.marker("slow-thread-start")
        let task = try f.store.createTask(projectId: f.project.id, title: "Cold start")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("first turn after a slow conversation start") { try !f.store.all(Question.self).isEmpty }
        let current = try f.store.get(WorkTask.self, task.id)
        #expect(!current.paused && current.retry == nil)
        await core.shutdown(); try f.cleanup()
    }

    @Test func evidenceCannotReachHumanReviewBeforeInspectionOfTheCurrentRevision() async throws {
        let f = try await Fixture()
        try f.marker("hold-qa")
        let task = try f.store.createTask(projectId: f.project.id, title: "Inspect evidence")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("QA task question") { try !f.store.all(Question.self).isEmpty }
        try await core.answer(try #require(f.store.all(Question.self).first).id, text: "Plain")
        try await f.wait("pending semantic QA") { try f.store.all(Proof.self).first?.qaToken != nil }
        let proof = try #require(f.store.all(Proof.self).first)
        #expect(!proof.complete && proof.qaReview == nil)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        let receipt: JSON = .object(["proofToken": .string(proof.qaToken!), "assessment": .string("Checked"), "inspectedPaths": .array(proof.evidencePaths.map(JSON.string))])
        var stale = try f.store.get(WorkTask.self, task.id); stale.requirementsRevision += 1; try f.store.save(stale)
        do { try await core.completeQA(taskID: task.id, arguments: receipt); Issue.record("Accepted QA for stale requirements") } catch {}
        #expect(try !f.store.get(Proof.self, proof.id).complete)
        stale.requirementsRevision -= 1; try f.store.save(stale)
        do { try await core.completeQA(taskID: task.id, arguments: .object(["proofToken": .string(proof.qaToken!), "assessment": .string("Checked"), "inspectedPaths": .array([])])); Issue.record("Accepted QA without inspecting artifacts") } catch {}
        try FileManager.default.removeItem(at: f.control.appending(path: "hold-qa"))
        try await f.wait("review after inspection") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.get(Proof.self, proof.id).qaReview != nil)
        await core.shutdown(); try f.cleanup()
    }

    @Test func overlappingScopesYieldWhileIndependentWorkRunsWithinTheAgentLimit() async throws {
        let f = try await Fixture()
        var settings = try f.store.settings(); settings.agentsAtOnce = 2; try f.store.saveSettings(settings)
        try f.marker("stall")
        var first = try f.store.createTask(projectId: f.project.id, title: "Shared module", rank: 30)
        first.affectedPaths = ["sources"]; try f.store.save(first)
        var overlapping = try f.store.createTask(projectId: f.project.id, title: "Same module", rank: 20)
        overlapping.affectedPaths = ["sources/search.swift"]; try f.store.save(overlapping)
        var independent = try f.store.createTask(projectId: f.project.id, title: "Independent docs", rank: 10)
        independent.affectedPaths = ["docs"]; try f.store.save(independent)
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("independent work alongside shared scope") { try f.store.session(for: first.id).currentTurn != nil && f.store.session(for: independent.id).currentTurn != nil }
        #expect(try f.store.get(WorkTask.self, overlapping.id).worktreePath == nil)
        try await core.pause(first.id, paused: true)
        try await f.wait("overlap proceeds after scope released") { try f.store.session(for: overlapping.id).currentTurn != nil }
        #expect(try f.store.all(Session.self).filter { $0.currentTurn != nil }.count == 2)
        await core.shutdown(); try f.cleanup()
    }

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
            project.settings.readTimeoutMs = 15_000 // Allow native subprocess startup under host load; stall/timeout tests override their own limits.
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
            // Bound observed polling, not elapsed host time: suspension/clock jumps must not
            // fail a completed subprocess before the test has had a chance to observe it.
            for _ in 0..<2000 {
                if try predicate() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw CoreError.invalid("Timed out: \(description)")
        }
        func cleanup() throws { try FileManager.default.removeItem(at: root) }
    }

    @Test func legacyBacklogMigrationAppendsToQueueWithoutLosingTaskDataOrPause() async throws {
        let f = try await Fixture()
        let queued = try f.store.createTask(projectId: f.project.id, title: "Already queued", rank: -10)
        let first = try f.store.createTask(projectId: f.project.id, title: "First legacy draft", description: "Keep this brief", rank: 100, files: [f.control.appending(path: "proof.png")])
        var second = try f.store.createTask(projectId: f.project.id, title: "Paused dependent draft", rank: 50, dependsOn: [first.id])
        second.paused = true; try f.store.save(second)
        let createdAt = try f.store.get(WorkTask.self, first.id).createdAt
        let session = try f.store.session(for: first.id)
        try f.store.save(Message(sessionId: session.id, role: "user", body: "Keep this conversation"))
        let secondID = second.id
        // Simulate the pre-upgrade database without retaining a legacy state in the app model.
        try await f.store.db.write { db in
            try db.execute(sql: "UPDATE task SET state = 'backlog' WHERE id IN (?, ?)", arguments: [first.id, secondID])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8-queue-only'")
        }
        let upgraded = try Store(root: f.store.root)
        let tasks = try upgraded.all(WorkTask.self).sorted { $0.rank > $1.rank }
        #expect(tasks.map(\.id) == [queued.id, first.id, second.id])
        #expect(tasks.allSatisfy { $0.state == .todo && $0.worktreePath == nil })
        #expect(!tasks[1].paused && tasks[2].paused && tasks[2].dependsOn == [first.id])
        #expect(tasks[1].description == first.description && tasks[1].createdAt == createdAt)
        #expect(try upgraded.all(Message.self).first?.body == "Keep this conversation")
        #expect(try upgraded.all(Attachment.self).allSatisfy { $0.ownerId == first.id && FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Store(root: f.store.root).all(WorkTask.self).sorted { $0.rank > $1.rank }.map(\.id) == tasks.map(\.id))
        try f.cleanup()
    }

    @Test func providerMigrationPreservesNativeSessionModelAndAcknowledgedInput() async throws {
        let f = try await Fixture()
        let task = try f.store.createTask(projectId: f.project.id, title: "Resume existing work")
        var session = try f.store.session(for: task.id)
        session.providerSessionID = "existing-codex-thread"; try f.store.save(session)
        let message = Message(sessionId: session.id, role: "user", body: "Already delivered")
        try f.store.save(message)
        try f.store.save(AgentConfiguration(id: task.id, model: "gpt-6-astra", effort: "high"))
        try f.store.acknowledgeInput(session: session, ids: [message.id], context: "Existing guidance")
        // Reconstruct the shipped schema, then exercise the real migration.
        try await f.store.db.write { db in
            try db.execute(sql: "ALTER TABLE session RENAME COLUMN providerSessionID TO codexThreadId")
            for table in ["session", "agentConfiguration", "agentDelivery"] {
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN provider")
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v17-agent-provider'")
        }
        let upgraded = try Store(root: f.store.root)
        let restored = try upgraded.session(for: task.id)
        #expect(restored.provider == .codex && restored.providerSessionID == "existing-codex-thread")
        let config = try upgraded.get(AgentConfiguration.self, task.id)
        #expect(config.provider == .codex && config.model == "gpt-6-astra" && config.effort == "high")
        #expect(try !upgraded.hasUndeliveredMessages(restored))
        let input = try upgraded.agentInput(session: restored, context: "Existing guidance", attachments: [])
        #expect(input.ids.isEmpty && !input.text.contains("Already delivered") && !input.text.contains("Existing guidance"))
        try f.cleanup()
    }

    @Test @MainActor func deletingRunningTaskStopsProcessesRemovesDirtyWorkAndNeverReusesItsNumber() async throws {
        var f = try await Fixture()
        f.project.settings.previewCommand = "preview"
        f.project.settings.stallTimeoutMs = 0
        try f.store.save(f.project)
        try f.marker("stall"); try f.marker("ignore-interrupt")
        let model = AppModel(store: f.store, runner: f.runner)
        let task = try f.store.createTask(projectId: f.project.id, title: "Delete while running", state: .todo, files: [f.control.appending(path: "proof.png")])
        await model.core.tick()
        let deadline = Date().addingTimeInterval(20)
        while try f.store.session(for: task.id).currentTurn == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try f.store.session(for: task.id).currentTurn != nil)
        let running = try f.store.get(WorkTask.self, task.id)
        let cwd = try #require(running.worktreePath)
        try "unfinished".write(toFile: cwd + "/uncommitted.txt", atomically: true, encoding: .utf8)
        let url = try await model.core.startPreview(task.id)
        try await model.core.setModel(ownerID: task.id, projectChat: false, model: "gpt-6-astra", effort: "high")
        let session = try f.store.session(for: task.id)
        _ = try f.store.saveChatMessage(Message(sessionId: session.id, role: "user", body: "Keep this attachment"), files: [f.control.appending(path: "proof.png")], projectID: f.project.id, ownerID: task.id)
        var dependent = try f.store.createTask(projectId: f.project.id, title: "Dependent", state: .todo, dependsOn: [task.id])
        dependent.stackOn = task.id; try f.store.save(dependent)
        await model.refresh(); model.destination = .task(task.id)
        f.project.settings.hooks.beforeRemove = "exit 7"; try f.store.save(f.project)
        do { try await model.deleteTask(running); Issue.record("Deleted despite failed cleanup hook") } catch {}
        #expect(try f.store.get(WorkTask.self, task.id).paused)
        #expect(FileManager.default.fileExists(atPath: cwd + "/uncommitted.txt"))
        f.project.settings.hooks.beforeRemove = ""; try f.store.save(f.project)
        try await model.deleteTask(running)
        #expect(model.destination == .project(f.project.id, .tasks))
        #expect(!model.snapshot.tasks.contains { $0.id == task.id })
        #expect(!model.snapshot.sessions.contains { $0.ownerId == task.id })
        #expect(!model.snapshot.messages.contains { $0.sessionId == session.id })
        #expect(!model.snapshot.agentConfigurations.contains { $0.id == task.id })
        #expect(try f.store.all(Attachment.self).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cwd))
        #expect(!FileManager.default.fileExists(atPath: f.store.root.appending(path: "projects/\(f.project.id)/media/\(task.id)").path))
        #expect(await model.core.previews[task.id] == nil)
        #expect(await model.core.proofsRunning == 0)
        do { _ = try await URLSession.shared.data(from: url); Issue.record("Deleted task left preview running") } catch {}
        let remaining = try f.store.get(WorkTask.self, dependent.id)
        #expect(remaining.paused && remaining.dependsOn.isEmpty && remaining.stackOn == nil)
        #expect(try await f.runner.run("git", ["show-ref", "--verify", "refs/heads/" + running.branchName!], cwd: f.repo.path).status == 0)
        // Removing the highest number must not reuse a retained branch on the next creation.
        try await model.deleteTask(remaining)
        let next = try f.store.createTask(projectId: f.project.id, title: task.title)
        #expect(next.number > dependent.number)
        await model.core.tick(); await model.refresh()
        #expect(!model.snapshot.tasks.contains { $0.id == task.id }) // Late worker cleanup cannot resurrect it.
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        await model.core.shutdown()
        try f.cleanup()
    }

    @Test func lifecycleKeepsCloneCleanGatesProofAndFinishesOnlyAfterMerge() async throws {
        var f = try await Fixture()
        // Catch missing Git metadata grants and grants that expose the main checkout/ref/config.
        try f.marker("sandbox-git")
        try f.marker("json-pr-summary")
        try f.marker("proof-efficiency")
        f.project.settings.askBeforeBuild = false
        f.project.settings.stallTimeoutMs = 750
        f.project.settings.recordingCommand = nil
        let sharedCheck = #"printf 'checked\n' >> "$TMPDIR/../fixture-checks"; if test -f "$BUILD_MATE_FIXTURE/proof-repaired"; then exit 0; fi; printf '%10000s\n' padding; printf '%s\n' 'TOKEN=fixture-proof-secret' 'proof diagnostic sentinel'; exit 1"#
        f.project.settings.checks.append(CheckDefinition(name: "Shared proof check", command: sharedCheck, required: false))
        try f.store.save(f.project)
        let core = Orchestrator(store: f.store, runner: f.runner)
        let task = try f.store.createTask(projectId: f.project.id, title: "Add plain output", state: .todo, proofRequirement: .checksAndRecording, askBeforeBuild: true)
        #expect(task.state == .todo)
        _ = try await core.models()
        do { try await core.setModel(ownerID: task.id, projectChat: false, model: "gpt-5.6-luna", effort: "ultra"); Issue.record("Accepted unsupported effort") } catch {}
        await core.tick()
        try await f.wait("blocking question") { try f.store.get(WorkTask.self, task.id).state == .needsClarification }
        #expect(try await core.steer(task.id, text: "Keep the output compact", files: [f.control.appending(path: "proof.png")]) == .sent)
        let attached = try #require(f.store.all(Attachment.self).first)
        #expect(attached.kind == "image" && FileManager.default.fileExists(atPath: attached.path))
        #expect(try String(contentsOf: f.control.appending(path: "image-inputs.jsonl"), encoding: .utf8).contains("turn/steer"))
        let question = try #require(f.store.all(Question.self).first)
        let thread = try #require(f.store.session(for: task.id).providerSessionID)
        let currentTurn = try f.store.session(for: task.id).currentTurn
        try await core.setModel(ownerID: task.id, projectChat: false, model: "gpt-6-astra", effort: "high")
        #expect(try f.store.session(for: task.id).currentTurn == currentTurn)
        #expect(try f.store.session(for: task.id).activeModel == "fake-model")
        #expect(try f.store.get(WorkTask.self, task.id).state == .needsClarification)
        #expect(try Store(root: f.store.root).get(AgentConfiguration.self, task.id).model == "gpt-6-astra")
        // A human may take longer than the stall window; answering must still resume.
        try await Task.sleep(for: .seconds(1))
        #expect(question.suggestedAnswer == "Plain")
        try await core.answer(question.id, text: "Plain", useSuggested: true)
        #expect(try f.store.get(Question.self, question.id).answeredBy == "agentDefault")
        try await f.wait("plan approval") { try !f.store.all(Approval.self).isEmpty }
        #expect(try f.store.get(WorkTask.self, task.id).state == .todo)
        try await core.approvePlan(f.store.all(Approval.self)[0].id)
        try await f.wait("human review") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.session(for: task.id).providerSessionID == thread)
        let proof = try #require(f.store.all(Proof.self).first)
        #expect(proof.complete && proof.checks.allSatisfy { $0.status == "passed" })
        #expect(proof.recordingRequired && proof.recordingDuration != nil)
        #expect(try f.store.all(Message.self).filter { $0.kind == "proof" }.count == 2) // A required duplicate check and invalid video must both block review.
        #expect(try f.store.all(Message.self).contains { $0.kind == "proof" }) // Failed proof reached the agent before review.
        #expect(proof.checks.filter { $0.name == "Shared proof check" }.count == 1)
        #expect(!proof.checks.contains { $0.name == "Agent shared check" })
        let media = f.store.root.appending(path: "projects/\(f.project.id)/media/\(task.id)")
        // The identical optional/configured and required/submitted command runs once per attempt,
        // and the failed first check must skip both expensive visual commands.
        #expect(try String(contentsOf: media.appending(path: "fixture-checks"), encoding: .utf8).split(separator: "\n").count == 3)
        for name in ["fixture-recordings", "fixture-screenshots"] {
            #expect(try String(contentsOf: media.appending(path: name), encoding: .utf8).split(separator: "\n").count == 2)
        }
        let proofFeedback = try String(contentsOf: f.control.appending(path: "proof-feedback.txt"), encoding: .utf8)
        #expect(proofFeedback.contains("Shared proof check") && proofFeedback.contains("proof diagnostic sentinel"))
        #expect(proofFeedback.contains("/logs/\(task.id)/") && proofFeedback.contains("[REDACTED]"))
        #expect(!proofFeedback.contains("fixture-proof-secret") && proofFeedback.count < 2_300)
        try FileManager.default.removeItem(at: f.control.appending(path: "proof-efficiency"))
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
        #expect(try f.store.session(for: task.id).providerSessionID == thread)
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("Preserve errors in the compact output"))
        #expect(try f.store.session(for: task.id).activeModel == "gpt-6-astra")
        #expect(try f.store.session(for: task.id).activeEffort == "high")
        let turnRequests = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }.filter { $0["method"].string == "turn/start" }
        #expect(turnRequests.last?["params"]["model"].string == "gpt-6-astra")
        #expect(turnRequests.last?["params"]["effort"].string == "high")
        let resumedInput = try #require(turnRequests.last?["params"]["input"].array)
        #expect(!resumedInput.contains { $0["type"].string == "localImage" })
        #expect(!resumedInput.compactMap { $0["text"].string }.joined().contains("Keep the output compact")) // Successful steering acknowledges its message and image before a later turn starts.
        try await core.setModel(ownerID: task.id, projectChat: false, model: "gpt-6-astra", effort: "low")
        #expect(try f.store.all(Proof.self).first?.complete == true) // Preferences do not invalidate reviewed work.
        // Chat review feedback preserves context and pause, and a changed reviewed commit cannot be published.
        do { try await core.steer(task.id, text: "  "); Issue.record("Accepted empty feedback") } catch {}
        let worktree = try #require(f.store.get(WorkTask.self, task.id).worktreePath)
        #expect(try f.store.all(Proof.self).first?.changes.map(\.path) == ["feature.txt"])
        _ = try await f.runner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Changed after review"], cwd: worktree)
        do { try await core.openPullRequest(task.id); Issue.record("Published a commit without proof") } catch {}
        try await core.pause(task.id, paused: true)
        #expect(try await core.steer(task.id, text: "Please verify the revised commit") == .queued)
        #expect(try f.store.all(Message.self).filter { $0.role == "user" && $0.body == "Please verify the revised commit" }.count == 1)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        #expect(try f.store.get(WorkTask.self, task.id).paused)
        #expect(try f.store.all(Proof.self).allSatisfy { !$0.complete })
        try await core.pause(task.id, paused: false)
        try await f.wait("fresh proof after chat feedback") { try f.store.get(WorkTask.self, task.id).state == .humanReview }
        #expect(try f.store.session(for: task.id).providerSessionID == thread)
        #expect(try f.store.all(Approval.self).filter { $0.status == "approved" }.count == 1)
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("Please verify the revised commit"))
        #expect(try f.store.session(for: task.id).activeEffort == "low")
        await core.shutdown()

        // Reopen SQLite and the orchestrator at the human-review boundary.
        let reopened = try Store(root: f.store.root)
        let resumed = Orchestrator(store: reopened, runner: f.runner)
        try await resumed.recover()
        // Never publish an unrecognised evidence report, even when the implementation passed proof.
        var savedProof = try #require(reopened.all(Proof.self).first { $0.taskId == task.id })
        let originalSummary = savedProof.summary
        savedProof.summary = #"{"proof":{"recording":"Private evidence"}}"#
        try reopened.save(savedProof)
        do { try await resumed.openPullRequest(task.id); Issue.record("Published proof metadata as a PR description") } catch {}
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "pr-created").path))
        savedProof.summary = originalSummary
        try reopened.save(savedProof)
        try await resumed.openPullRequest(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        do { try await resumed.editTask(task.id, title: "Changed scope", description: "Different work", proofRequirement: .checksOnly); Issue.record("PR task scope edited") } catch {}
        try await resumed.editTask(task.id, title: "Clear plain output", description: edited.description, proofRequirement: edited.proofRequirement)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        #expect(try reopened.get(WorkTask.self, task.id).branchName == originalBranch)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        let branch = try #require(reopened.get(WorkTask.self, task.id).branchName)
        #expect(try String(contentsOf: f.control.appending(path: "pr-body"), encoding: .utf8) == "- Adds the requested feature.\n- Preserves **existing behavior**.")

        // In-PR feedback must resume the same task, require fresh proof, and publish a new commit to the same PR.
        var published = try reopened.get(WorkTask.self, task.id)
        let originalPR = try #require(published.pr)
        let originalRemoteHead = try await f.runner.run("git", ["--git-dir", f.remote.path, "rev-parse", "refs/heads/" + branch]).output
        published.paused = true; try reopened.save(published)
        for marker in ["pr-closed", "merged"] {
            try f.marker(marker)
            do { _ = try await resumed.steer(task.id, text: "This PR cannot receive changes"); Issue.record("Resumed a closed or merged PR") } catch {}
            #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
            #expect(try reopened.all(Message.self).allSatisfy { $0.body != "This PR cannot receive changes" })
            #expect(try reopened.all(Proof.self).first { $0.taskId == task.id }?.complete == true)
            try FileManager.default.removeItem(at: f.control.appending(path: marker))
        }
        #expect(try await resumed.steer(task.id, text: "Change the feature to blue", files: [f.control.appending(path: "proof.png")]) == .queued)
        let revising = try reopened.get(WorkTask.self, task.id)
        #expect(revising.state == .building && revising.paused)
        #expect(revising.branchName == branch && revising.worktreePath == published.worktreePath)
        #expect(revising.pr?.number == originalPR.number && revising.pr?.url == originalPR.url)
        #expect(try reopened.session(for: task.id).providerSessionID == thread)
        #expect(try reopened.all(Proof.self).allSatisfy { !$0.complete })
        let feedback = try #require(reopened.all(Message.self).first { $0.body == "Change the feature to blue" })
        #expect(try reopened.all(Attachment.self).contains { $0.ownerId == feedback.id && FileManager.default.fileExists(atPath: $0.path) })
        do { try await resumed.openPullRequest(task.id); Issue.record("Published revision before fresh proof") } catch {}
        try f.marker("pr-revision")
        try await resumed.pause(task.id, paused: false)
        try await f.wait("PR feedback clarification") { try reopened.get(WorkTask.self, task.id).state == .needsClarification }
        let revisionQuestion = try #require(reopened.all(Question.self).first { $0.taskId == task.id && $0.answer == nil })
        #expect(revisionQuestion.prompt == "Which shade of blue?")
        try await resumed.answer(revisionQuestion.id, text: "Light")
        try await f.wait("fresh PR revision proof and finished worker") {
            try reopened.get(WorkTask.self, task.id).state == .humanReview && reopened.session(for: task.id).status == "idle"
        }
        #expect(try reopened.session(for: task.id).providerSessionID == thread)
        let revisedHead = try await f.runner.run("git", ["rev-parse", "HEAD"], cwd: worktree).output
        #expect(revisedHead != originalRemoteHead)
        #expect(try await f.runner.run("git", ["--git-dir", f.remote.path, "rev-parse", "refs/heads/" + branch]).output == originalRemoteHead)
        for marker in ["pr-closed", "merged"] {
            try f.marker(marker)
            do { try await resumed.openPullRequest(task.id); Issue.record("Updated a closed or merged PR") } catch {}
            #expect(try reopened.get(WorkTask.self, task.id).state == .humanReview)
            #expect(try await f.runner.run("git", ["--git-dir", f.remote.path, "rev-parse", "refs/heads/" + branch]).output == originalRemoteHead)
            try FileManager.default.removeItem(at: f.control.appending(path: marker))
        }
        try await resumed.openPullRequest(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .inPR)
        #expect(try reopened.get(WorkTask.self, task.id).pr?.number == originalPR.number)
        #expect(try await f.runner.run("git", ["--git-dir", f.remote.path, "rev-parse", "refs/heads/" + branch]).output == revisedHead)
        let ghCalls = try String(contentsOf: f.control.appending(path: "gh-calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        #expect(ghCalls.filter { Array($0.prefix(2)) == ["pr", "create"] }.count == 1)
        #expect(ghCalls.filter { Array($0.prefix(2)) == ["pr", "edit"] }.count == 1)
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("Change the feature to blue"))
        // Simulate the host merge in the real bare remote; no network host exists in this test.
        _ = try await f.runner.run("git", ["--git-dir", f.remote.path, "update-ref", "refs/heads/main", "refs/heads/" + branch])
        try f.marker("merged")
        let mergedPath = try #require(reopened.get(WorkTask.self, task.id).worktreePath)
        let unsaved = URL(fileURLWithPath: mergedPath).appending(path: "unsaved.txt")
        try "Preserve this local work".write(to: unsaved, atomically: true, encoding: .utf8)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).state == .done)
        #expect(try reopened.get(WorkTask.self, task.id).doneAt != nil)
        #expect(try reopened.get(Attachment.self, attached.id).removedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: attached.path))
        #expect(!FileManager.default.fileExists(atPath: attached.frames[0]))
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "proof.png").path))
        #expect(FileManager.default.fileExists(atPath: unsaved.path)) // A merge must never force-delete uncommitted work.
        try FileManager.default.removeItem(at: unsaved)
        await resumed.pollPR(task.id)
        #expect(try reopened.get(WorkTask.self, task.id).worktreePath == nil)
        #expect(!FileManager.default.fileExists(atPath: mergedPath))
        #expect(await resumed.backgroundIssues.isEmpty)
        #expect(try reopened.all(Proof.self).contains { $0.taskId == task.id })
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.repo.path)) == Set([".git", "README.md"]))
        #expect(try String(contentsOf: f.control.appending(path: "pr-body"), encoding: .utf8) == "- Changes the feature to blue.\n- Preserves **existing behavior**.")
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
            // Old summary-only threads can nest a JSON summary inside the report: render all evidence readably.
            if !visual {
                #expect(proof.reviewSummary.contains("### Changes\n\nAdds the requested feature."))
                #expect(proof.reviewSummary.contains("#### Limitations\n\nNo live interaction test."))
                #expect(proof.reviewSummary.contains("- abc123"))
                #expect(proof.reviewSummary.contains("### Extra detail\n\nPreserve this unknown field."))
                #expect(proof.summary.hasPrefix("{")) // Reading old evidence must not rewrite it.
            } else {
                #expect(proof.reviewSummary == "Adds the requested feature.")
            }
            #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "forbidden-write").path))
            let recording = visual && requirement != .checksOnly
            #expect(proof.recordingRequired == recording)
            #expect(proof.screenshots.count == (recording ? 2 : 0))
            #expect((proof.recordingPath != nil) == recording)
            #expect(try f.store.all(Message.self).filter { $0.kind == "proof" }.count == (recording ? 2 : visual ? 0 : 1))
            if requirement == .checksOnly {
                try await core.openPullRequest(task.id)
                #expect(try String(contentsOf: f.control.appending(path: "pr-body"), encoding: .utf8) == "Adds the requested feature.")
            }
            if !visual {
                try f.marker("always-fail-proof")
                try await core.steer(task.id, text: "Exercise failed proof recovery")
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

    // Catches preview starvation of proof, port collisions, excess previews and orphan children.
    @Test func previewsLeaveProofCapacityAndReleasePortsOnStopFailureAndQuit() async throws {
        var f = try await Fixture()
        f.project.paused = true
        f.project.settings.previewCommand = "preview"
        f.project.settings.previewPortEnvVar = "CUSTOM_PORT"
        f.project.settings.previewReadyPath = "/health"
        try f.store.save(f.project)
        let workspace = Workspace(store: f.store, runner: f.runner)
        var preparedTasks: [WorkTask] = []
        for title in ["First preview", "Second preview", "Waiting preview"] {
            var task = try f.store.createTask(projectId: f.project.id, title: title, state: .todo)
            task.paused = true; try f.store.save(task)
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
        // Both long-lived previews keep serving while a separate fake-Codex task completes real proof.
        let verification = try f.store.createTask(projectId: f.project.id, title: "Verify while previews run", proofRequirement: .checksOnly)
        f.project.paused = false; try f.store.save(f.project)
        await core.tick()
        try await f.wait("verification question") { try f.store.all(Question.self).contains { $0.taskId == verification.id && $0.answer == nil } }
        let question = try #require(f.store.all(Question.self).first { $0.taskId == verification.id && $0.answer == nil })
        try await core.answer(question.id, text: "Plain")
        try await f.wait("proof completes with both previews running") {
            try f.store.get(WorkTask.self, verification.id).state == .humanReview && f.store.session(for: verification.id).status == "idle"
        }
        #expect(try f.store.all(Proof.self).first { $0.taskId == verification.id }?.complete == true)
        #expect(await core.proofsRunning == 0)
        for (index, url) in urls.enumerated() {
            #expect(await core.previews[tasks[index].id]?.phase == "ready")
            let (data, _) = try await URLSession.shared.data(from: url)
            #expect(String(decoding: data, as: UTF8.self) == String(tasks[index].number))
        }
        await core.stopPreview(tasks[0].id)
        #expect(await core.previews[tasks[0].id] == nil)
        do { _ = try await URLSession.shared.data(from: urls[0]); Issue.record("Stopped preview still serves HTTP") } catch {}
        f.project.settings.previewCommand = "preview --never-ready"
        try f.store.save(f.project)
        do { _ = try await core.startPreview(tasks[2].id, timeout: 0.5); Issue.record("Unready preview was accepted") } catch {}
        #expect(await core.previews[tasks[2].id]?.phase == "failed")
        #expect(await core.previewProcesses.count == 1)
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
        #expect(await core.previewProcesses.count == 1)
        await core.shutdown()
        #expect(await core.previews.isEmpty)
        #expect(await core.previewProcesses.isEmpty)
        #expect(await core.proofsRunning == 0)
        do { _ = try await URLSession.shared.data(from: urls[1]); Issue.record("Quit left preview running") } catch {}
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        try f.cleanup()
    }

    @Test func schedulerRespectsRankDependenciesPauseAndResumesThreadAfterCrash() async throws {
        var f = try await Fixture()
        try f.marker("configured-model")
        f.project.settings.stallTimeoutMs = 500
        try f.store.save(f.project)
        var settings = AppSettings(); settings.agentsAtOnce = 1; try f.store.saveSettings(settings)
        var held = try f.store.createTask(projectId: f.project.id, title: "Paused prerequisite", rank: 100)
        held.paused = true; try f.store.save(held)
        let dependency = try f.store.createTask(projectId: f.project.id, title: "Blocked", state: .todo, rank: 90, dependsOn: [held.id])
        let high = try f.store.createTask(projectId: f.project.id, title: "First", description: "Original task brief marker", state: .todo, rank: 10, files: [f.control.appending(path: "proof.png")])
        let highSession = try f.store.session(for: high.id)
        try f.store.save(Message(sessionId: highSession.id, role: "user", body: "Original user request marker"))
        let low = try f.store.createTask(projectId: f.project.id, title: "Second", state: .todo, rank: 20)
        let ordering = await AppModel(store: f.store, runner: f.runner)
        try await ordering.reorderTask(high.id, relativeTo: low.id, after: false) // The next dispatch follows the user’s reordered queue.
        try f.marker("crash-once")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("retry after process exit") { try f.store.get(WorkTask.self, high.id).retry != nil }
        let first = try f.store.get(WorkTask.self, high.id)
        await ordering.refresh()
        #expect(await ordering.needsYou(first) == false) // Automatic recovery must not create a human-action alert.
        #expect(await ordering.attentionItems.isEmpty)
        #expect(try f.store.get(WorkTask.self, low.id).worktreePath == nil)
        #expect(try f.store.get(WorkTask.self, dependency.id).worktreePath == nil)
        #expect(try f.store.get(WorkTask.self, held.id).worktreePath == nil)
        #expect(first.retry!.dueAt.timeIntervalSince(first.createdAt) >= 10)
        let thread = try #require(f.store.session(for: high.id).providerSessionID)
        // Hold other candidates so the retry deadline is observable at the process boundary.
        try await core.pause(low.id, paused: true)
        await core.tick()
        #expect(try f.store.session(for: high.id).turnCount == 1)
        await core.shutdown()

        f.project.settings.model = "fake-model"; f.project.settings.effort = "low"; try f.store.save(f.project)
        try f.store.save(Message(sessionId: highSession.id, role: "user", body: "Follow-up user request marker"))
        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        try await resumed.recover()
        try f.marker("stall")
        await resumed.tick(now: first.retry!.dueAt.addingTimeInterval(1))
        try await f.wait("stall retry and cleanup") {
            try f.store.get(WorkTask.self, high.id).retry?.attempt == 2 && f.store.all(RunAttempt.self).contains { $0.status == "stalled" }
        }
        // Observe the reopened store without starting a competing get-or-create write transaction.
        #expect(try f.store.all(Session.self).first { $0.ownerId == high.id }?.providerSessionID == thread)
        #expect(try f.store.all(RunAttempt.self).contains { $0.status == "stalled" })
        try FileManager.default.removeItem(at: f.control.appending(path: "stall"))
        let second = try f.store.get(WorkTask.self, high.id)
        await resumed.shutdown()
        try f.store.saveInstructions("Changed project guidance marker", projectID: f.project.id)
        let third = Orchestrator(store: f.store, runner: f.runner)
        await third.tick(now: second.retry!.dueAt.addingTimeInterval(1))
        try await f.wait("question on resumed thread") { try f.store.get(WorkTask.self, high.id).state == .needsClarification }
        // A durable human wait releases the sole agent slot for independent work.
        var available = try f.store.get(WorkTask.self, low.id); available.paused = false; try f.store.save(available)
        await third.tick()
        try await f.wait("independent work uses the released slot") { try f.store.get(WorkTask.self, low.id).worktreePath != nil }
        #expect(try f.store.session(for: high.id).currentTurn == nil)
        try await third.pause(high.id, paused: true)
        await third.shutdown()
        #expect(try f.store.get(WorkTask.self, high.id).paused)
        #expect(FileManager.default.fileExists(atPath: first.worktreePath!))
        let calls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)
        #expect(calls.contains("thread/resume"))
        #expect(calls.contains("turn/interrupt"))
        let turns = try calls.split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }.filter { $0["method"].string == "turn/start" && $0["params"]["threadId"].string == thread }
        try #require(turns.count == 3)
        let inputs = turns.map { $0["params"]["input"].array.compactMap { $0["text"].string }.joined(separator: "\n") }
        #expect(inputs[0].contains("Original task brief marker") && inputs[0].contains("Original user request marker"))
        #expect(!inputs[1].contains("Original user request marker") && inputs[1].contains("Follow-up user request marker"))
        #expect(inputs[2].contains("Changed project guidance marker") && !inputs[2].contains("Follow-up user request marker") && !inputs[2].contains("Original user request marker"))
        #expect(turns.map { $0["params"]["input"].array.filter { $0["type"].string == "localImage" }.count } == [1, 0, 0])
        #expect(turns[0]["params"]["model"].string == "gpt-6-astra") // Resolved CLI model overrides the catalogue's fake-model recommendation.
        #expect(turns[0]["params"]["effort"].string == "high") // Inherit CLI configuration, not the model catalogue's medium default.
        #expect(turns[1]["params"]["model"].string == "fake-model")
        #expect(turns[1]["params"]["effort"].string == "low") // Explicit project selection overrides inherited effort.
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
        #expect(try f.store.session(for: task.id).providerSessionID == nil)
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
        #expect(try f.store.get(WorkTask.self, task.id).paused)
        let attentionModel = await AppModel(store: f.store, runner: f.runner)
        await attentionModel.refresh()
        #expect(await attentionModel.attentionItems.count == 1) // Exhausted recovery, unlike scheduled retries, needs the user.
        await flood.shutdown()
        let worktrees = f.store.root.appending(path: "worktrees")
        try FileManager.default.moveItem(at: worktrees, to: f.store.root.appending(path: "retained-worktrees"))
        try FileManager.default.createSymbolicLink(at: worktrees, withDestinationURL: f.repo)
        let escaped = Orchestrator(store: f.store, runner: f.runner)
        try await escaped.pause(task.id, paused: false)
        try await f.wait("reject escaped root before any hook or git mutation") {
            try f.store.get(WorkTask.self, task.id).retry?.attempt == 1 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        #expect(try f.store.get(WorkTask.self, task.id).retry!.error.contains("outside Build Mate storage"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.repo.path)) == Set([".git", "README.md"]))
        await escaped.shutdown()
        try f.cleanup()
    }

    // Catches child/foreign events finishing or mutating the parent, lost delegated results and orphaned delegation on stop.
    @Test func delegatedAgentsStayIsolatedPersistResultsAndStopWithTheirTask() async throws {
        let f = try await Fixture()
        try f.marker("subagents")
        let task = try f.store.createTask(projectId: f.project.id, title: "Coordinate delegated research", proofRequirement: .checksOnly)
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("parent question after child completion") {
            try f.store.get(WorkTask.self, task.id).state == .needsClarification
                && (try? String(contentsOf: f.control.appending(path: "delegated-rejections.jsonl"), encoding: .utf8))?.contains("missing-thread-lifecycle") == true
        }
        let session = try f.store.session(for: task.id)
        let rootThread = try #require(session.providerSessionID)
        #expect(session.turnCount == 1 && session.tokensIn == 11 && session.tokensOut == 7)
        #expect(try f.store.all(Proof.self).isEmpty && f.store.all(Approval.self).isEmpty)
        #expect(try !f.store.all(Message.self).contains { $0.body.contains("Delegated findings") || $0.body.contains("CHILD MUST") || $0.body.contains("FOREIGN") })
        let generated = try f.store.all(Message.self).filter { $0.sessionId == session.id && $0.payload["generatedImageItemId"].string != nil }
        let generatedMessage = try #require(generated.first)
        let generatedAttachments = try f.store.chatAttachments(sessionID: session.id)
        let generatedAttachment = try #require(generatedAttachments.first)
        #expect(generated.count == 1 && generatedMessage.role == "agent" && generatedMessage.body.isEmpty)
        #expect(generatedAttachments.count == 1 && generatedAttachment.ownerId == generatedMessage.id && generatedAttachment.kind == "image")
        #expect(generatedAttachment.path != f.control.appending(path: "proof.png").path && FileManager.default.fileExists(atPath: generatedAttachment.path))
        #expect(!generatedAttachment.frames.isEmpty && FileManager.default.fileExists(atPath: generatedAttachment.frames[0]))
        #expect(try !f.store.all(Message.self).contains { $0.body.contains("RAW IMAGE RESULT") })
        let children = try f.store.all(Subagent.self).filter { $0.sessionId == session.id }
        #expect(children.count == 2 && children.allSatisfy { $0.parentThreadId == rootThread })
        let research = try #require(children.first { $0.threadId.contains("-research-") })
        #expect(research.status == "completed" && research.result == "Delegated findings only.")
        #expect(research.name.lowercased().contains("research"))
        let rejected = try String(contentsOf: f.control.appending(path: "delegated-rejections.jsonl"), encoding: .utf8)
        #expect(rejected.contains("delegated-lifecycle") && rejected.contains("foreign-lifecycle") && rejected.contains("missing-thread-lifecycle"))
        let question = try #require(f.store.all(Question.self).first { $0.taskId == task.id })
        try await core.answer(question.id, text: "Plain")
        try await f.wait("only the parent completes proof") {
            try f.store.get(WorkTask.self, task.id).state == .humanReview && f.store.session(for: task.id).status == "idle"
        }
        let fixtureState = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: rootThread + ".json")))
        // Active turns, early completion activity and pending follow-up interaction all block proof; the fourth request runs it once.
        #expect(fixtureState["delegated_review_gates"].int == 3 && fixtureState["reviews"].int == 4)
        let proofs = try f.store.all(Proof.self).filter { $0.taskId == task.id }
        #expect(proofs.count == 1 && proofs[0].complete)
        #expect(try f.store.all(Message.self).filter { $0.sessionId == session.id && $0.body == "Self-review completed. Ready for review." }.count == 1)
        #expect(try Store(root: f.store.root).get(Subagent.self, research.id).result == "Follow-up verified.")

        // Native child work belongs to the parent app-server process; pause and shutdown must stop it and persist that outcome.
        try f.marker("subagent-hold")
        let held = try f.store.createTask(projectId: f.project.id, title: "Hold delegated work")
        let heldSession = try f.store.session(for: held.id)
        await core.tick()
        try await f.wait("live delegated task") {
            try f.store.session(for: held.id).currentTurn != nil && f.store.all(Subagent.self).contains { $0.sessionId == heldSession.id && $0.threadId.hasSuffix("checker-turn-1") && $0.isActive }
        }
        let firstPID = try #require(Int32(String(contentsOf: f.control.appending(path: "delegating-pid"), encoding: .utf8)))
        let firstChildPID = try #require(Int32(String(contentsOf: f.control.appending(path: "delegated-command-pid"), encoding: .utf8)))
        let heldThread = try #require(f.store.session(for: held.id).providerSessionID)
        #expect(try f.store.get(WorkTask.self, held.id).state == .todo)
        try await core.pause(held.id, paused: true)
        try await f.wait("paused server PID \(firstPID) and child PID \(firstChildPID) exit") {
            kill(firstPID, 0) != 0 && kill(firstChildPID, 0) != 0
        }
        let pauseCalls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
        #expect(pauseCalls.contains { $0["method"].string == "turn/interrupt" && $0["params"]["threadId"].string == heldThread + "-checker-turn-1" && $0["params"]["turnId"].string == "child-turn-1-checker" })
        #expect(try f.store.all(Subagent.self).filter { $0.sessionId == heldSession.id }.allSatisfy { !$0.isActive })
        #expect(try f.store.all(Subagent.self).contains { $0.sessionId == heldSession.id && $0.status == "interrupted" })
        try await core.pause(held.id, paused: false)
        try await f.wait("delegation resumes in the same parent thread") {
            try f.store.session(for: held.id).turnCount == 2 && f.store.all(Subagent.self).contains { $0.sessionId == heldSession.id && $0.threadId.hasSuffix("checker-turn-2") && $0.isActive }
        }
        let resumedPID = try #require(Int32(String(contentsOf: f.control.appending(path: "delegating-pid"), encoding: .utf8)))
        let resumedChildPID = try #require(Int32(String(contentsOf: f.control.appending(path: "delegated-command-pid"), encoding: .utf8)))
        #expect(try f.store.session(for: held.id).providerSessionID == heldThread)
        await core.shutdown()
        try await f.wait("shutdown server PID \(resumedPID) and child PID \(resumedChildPID) exit") {
            kill(resumedPID, 0) != 0 && kill(resumedChildPID, 0) != 0
        }
        let shutdownCalls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
        #expect(shutdownCalls.contains { $0["method"].string == "turn/interrupt" && $0["params"]["threadId"].string == heldThread + "-checker-turn-2" && $0["params"]["turnId"].string == "child-turn-2-checker" })
        #expect(!shutdownCalls.filter { $0["method"].string == "turn/start" }.contains { $0["params"]["input"].array.contains { $0["type"].string == "localImage" } }) // Native generated output is already in Codex context; do not upload it back on resume.
        let savedChildren = try Store(root: f.store.root).all(Subagent.self).filter { $0.sessionId == heldSession.id }
        #expect(!savedChildren.isEmpty && savedChildren.allSatisfy { !$0.isActive })
        #expect(savedChildren.contains { $0.threadId.hasSuffix("checker-turn-2") && $0.status == "interrupted" })
        try f.cleanup()
    }

    @Test func repeatedEmptyResponsesStopWithoutImposingALifetimeTurnBudget() async throws {
        var f = try await Fixture()
        f.project.settings.stallTimeoutMs = 500; f.project.settings.turnTimeoutMs = 10_000; try f.store.save(f.project)
        let task = try f.store.createTask(projectId: f.project.id, title: "Recover an idle agent")
        var session = try f.store.session(for: task.id)
        session.turnCount = 25; try f.store.save(session)
        try f.marker("empty-responses")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("empty responses stop instead of looping") {
            try f.store.get(WorkTask.self, task.id).paused && f.store.all(RunAttempt.self).last?.endedAt != nil
        }
        #expect(try f.store.session(for: task.id).turnCount == 28)
        #expect(try f.store.get(WorkTask.self, task.id).retry?.error.contains("without taking action") == true)
        let thread = try f.store.session(for: task.id).providerSessionID
        try FileManager.default.removeItem(at: f.control.appending(path: "empty-responses"))
        try f.marker("note-only-responses")
        try await core.pause(task.id, paused: false)
        try await f.wait("notes alone cannot bypass the no-progress guard") {
            try f.store.get(WorkTask.self, task.id).paused && f.store.session(for: task.id).turnCount == 31 && f.store.all(RunAttempt.self).allSatisfy { $0.endedAt != nil }
        }
        #expect(try f.store.all(Message.self).filter { $0.body == "Still considering the same request." }.count == 3)
        try FileManager.default.removeItem(at: f.control.appending(path: "note-only-responses"))
        try f.marker("quiet-command")
        try await core.pause(task.id, paused: false)
        try await f.wait("task reply streams before item completion") {
            try f.store.all(Message.self).contains { $0.body == "Inspecting the selected files" && $0.payload["streaming"].bool == true }
        }
        try await f.wait("resume retains context past the former turn budget") {
            try f.store.get(WorkTask.self, task.id).state == .needsClarification
                && (try? String(contentsOf: f.control.appending(path: "native-responses.jsonl"), encoding: .utf8).split(separator: "\n").count) == 4
        }
        #expect(try f.store.session(for: task.id).providerSessionID == thread)
        #expect(try f.store.session(for: task.id).turnCount == 32 && f.store.get(WorkTask.self, task.id).retry == nil)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "quiet-command").path)) // The silent command exceeded stallTimeout, then finished normally.
        let messages = try f.store.all(Message.self)
        let replies = messages.filter { $0.body.hasPrefix("Inspecting the selected files") }
        #expect(replies.count == 1 && replies.first?.payload["streaming"].bool == false)
        #expect(!messages.contains { $0.body.contains("SECRET QUESTION") || $0.body.contains("PRIVATE APPROVAL DETAIL") })
        #expect(messages.contains { $0.kind == "error" && $0.body.contains("declined") })
        let questions = try f.store.all(Question.self)
        let optional = try #require(questions.first { $0.prompt == "Which optional format?" })
        #expect(!optional.blocking && !optional.allowsFreeText && optional.options == ["Plain", "Rich"])
        #expect(!questions.contains { $0.prompt.contains("SECRET QUESTION") })
        await core.shutdown()
        try f.cleanup()
    }

    @Test func transitionRulesRejectSkippingProofQuestionsPlanDependenciesOrMerge() throws {
        let allowed: [TaskState: Set<TaskState>] = [
            .todo: [.needsClarification, .building, .canceled],
            .needsClarification: [.todo, .building, .canceled],
            .building: [.needsClarification, .humanReview, .canceled],
            .humanReview: [.building, .inPR, .canceled],
            .inPR: [.building, .done, .canceled], .done: [], .canceled: []
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
