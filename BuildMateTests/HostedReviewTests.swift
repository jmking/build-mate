import Foundation
import Testing

@Suite(.serialized)
struct HostedReviewTests {
    @Test func githubRepairsFeedbackRetriesOnlyInspectedCIAndMergesTheApprovedHead() async throws {
        var f = try await CoreTests.Fixture()
        f.project.settings.askBeforeMerge = true; try f.store.save(f.project)
        try f.marker("json-pr-summary")
        let task = try f.store.createTask(projectId: f.project.id, title: "Hosted workflow")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("initial clarification") { try !f.store.all(Question.self).isEmpty }
        try await core.answer(try #require(f.store.all(Question.self).first).id, text: "Plain")
        try await f.wait("initial QA") { try f.store.get(WorkTask.self, task.id).state == .humanReview && f.store.session(for: task.id).status == "idle" }
        try await core.openPullRequest(task.id)
        // Triage is durable, rejects stale remote heads, and cannot blindly retry a failed run.
        try f.marker("ci-failed"); await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        let retry: JSON = .object(["action": .string("retry_ci"), "runId": .string("91"), "reason": .string("The log confirms the runner lost its network before tests started.")])
        do { _ = try await core.reviewAction(task.id, arguments: retry); Issue.record("Retried without inspecting failure logs") } catch {}
        let log = try await core.reviewAction(task.id, arguments: .object(["action": .string("inspect_ci"), "runId": .string("91")]))
        #expect(log.contains("No tests ran"))
        _ = try await core.reviewAction(task.id, arguments: retry)
        do { _ = try await core.reviewAction(task.id, arguments: retry); Issue.record("Retried the same CI attempt twice") } catch {}
        _ = try await core.reviewAction(task.id, arguments: .object(["action": .string("finish")]))
        await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .inPR) // An unchanged failed attempt must not trigger endless agent passes.
        try FileManager.default.removeItem(at: f.control.appending(path: "ci-failed"))
        try "[{\"id\":101,\"body\":\"Use blue for this existing requirement.\"}]".write(to: f.control.appending(path: "review-feedback"), atomically: true, encoding: .utf8)
        try f.marker("lose-reply-response"); try f.marker("thread-feedback"); try f.marker("hosted-feedback"); try f.marker("pr-revision")
        await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        await core.tick()
        try await f.wait("automatic same-PR repair and reply") { try f.store.get(WorkTask.self, task.id).state == .inPR && f.store.session(for: task.id).status == "idle" && FileManager.default.fileExists(atPath: f.control.appending(path: "posted-replies").path) }
        await core.pollPR(task.id) // Recover a posted reply whose CLI response was lost; do not duplicate it.
        let posts = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: "posted-replies")))
        #expect(posts.array.count == 2)
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "thread-resolved").path))
        #expect(try f.store.all(Proof.self).first?.qaReview != nil)
        await core.shutdown()
        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        let parent = WorkTask(projectId: f.project.id, number: 2, title: "Merged parent", state: .done)
        try f.store.save(parent)
        var child = try f.store.get(WorkTask.self, task.id); child.stackOn = parent.id; child.pr?.baseBranch = "parent-branch"; try f.store.save(child)
        try "parent-branch".write(to: f.control.appending(path: "pr-base"), atomically: true, encoding: .utf8)
        await resumed.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        #expect(try f.store.all(Proof.self).first?.complete == false)
        await resumed.tick()
        try await f.wait("stacked child reverified against main") { try f.store.get(WorkTask.self, task.id).state == .inPR && f.store.session(for: task.id).status == "idle" }
        try f.marker("merge-ready")
        await resumed.pollPR(task.id)
        let approval = try #require(f.store.all(Approval.self).first { $0.kind == "merge" && $0.status == "pending" })
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        var prerequisite = WorkTask(projectId: f.project.id, number: 3, title: "Required rollout step")
        prerequisite.paused = true; try f.store.save(prerequisite)
        _ = try await resumed.setTaskDependencies(task.id, projectID: f.project.id, dependencyIDs: [prerequisite.id])
        try await resumed.approveMerge(approval.id)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        _ = try await resumed.setTaskDependencies(task.id, projectID: f.project.id, dependencyIDs: [])
        await resumed.pollPR(task.id)
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        await resumed.pollPR(task.id)
        #expect(try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: "posted-replies"))).array.count == 2)
        let calls = try String(contentsOf: f.control.appending(path: "gh-calls.jsonl"), encoding: .utf8)
        let commands = try calls.split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)).array.compactMap(\.string) }
        #expect(commands.filter { $0.prefix(2) == ["pr", "merge"] }.count == 1)
        #expect(calls.contains("--match-head-commit") && !calls.contains("--admin"))
        try f.marker("merged"); await resumed.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .done)
        await resumed.shutdown(); try f.cleanup()
    }

    @Test func publicationExplainsARemoteBranchHoldingCommitsTheTaskDidNotMake() async throws {
        let f = try await CoreTests.Fixture()
        let task = try f.store.createTask(projectId: f.project.id, title: "Colliding branch")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("initial clarification") { try !f.store.all(Question.self).isEmpty }
        try await core.answer(try #require(f.store.all(Question.self).first).id, text: "Plain")
        try await f.wait("initial QA") { try f.store.get(WorkTask.self, task.id).state == .humanReview && f.store.session(for: task.id).status == "idle" }
        // Another clone already published different work under this branch name.
        let branch = try #require(f.store.get(WorkTask.self, task.id).branchName)
        try "foreign\n".write(to: f.repo.appending(path: "foreign.txt"), atomically: true, encoding: .utf8)
        _ = try await f.runner.run("git", ["add", "foreign.txt"], cwd: f.repo.path)
        _ = try await f.runner.run("git", ["-c", "user.name=Other", "-c", "user.email=other@example.invalid", "commit", "-m", "Foreign"], cwd: f.repo.path)
        _ = try await f.runner.run("git", ["push", "origin", "HEAD:refs/heads/" + branch], cwd: f.repo.path)
        do { try await core.openPullRequest(task.id); Issue.record("Published over a foreign remote branch") }
        catch { #expect(error.localizedDescription.contains("already has commits this task didn’t make")) }
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "pr-created").path))
        #expect(try f.store.get(WorkTask.self, task.id).state == .humanReview)
        await core.shutdown(); try f.cleanup()
    }

    @Test func bitbucketPublishesRepairsFeedbackResolvesTasksAndMergesWithTheRepositoryDefault() async throws {
        var f = try await CoreTests.Fixture()
        f.project.host = .bitbucket; try f.store.save(f.project)
        try f.marker("bitbucket")
        let task = try f.store.createTask(projectId: f.project.id, title: "Bitbucket workflow")
        let core = Orchestrator(store: f.store, runner: f.runner)
        await core.tick()
        try await f.wait("initial clarification") { try !f.store.all(Question.self).isEmpty }
        try await core.answer(try #require(f.store.all(Question.self).first).id, text: "Plain")
        try await f.wait("initial QA") { try f.store.get(WorkTask.self, task.id).state == .humanReview && f.store.session(for: task.id).status == "idle" }
        try await core.openPullRequest(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).pr?.url == "https://bitbucket.org/fixture/repo/pull-requests/7")
        #expect(try f.store.get(WorkTask.self, task.id).state == .inPR)

        // A failed Pipelines run is inspected before an evidenced retry, and retried at most once per attempt.
        try f.marker("ci-failed"); await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        let retry: JSON = .object(["action": .string("retry_ci"), "runId": .string("12"), "reason": .string("The log shows the runner lost its network before tests ran.")])
        do { _ = try await core.reviewAction(task.id, arguments: retry); Issue.record("Retried without inspecting failure logs") } catch {}
        #expect(try await core.reviewAction(task.id, arguments: .object(["action": .string("inspect_ci"), "runId": .string("12")])).contains("No tests ran"))
        _ = try await core.reviewAction(task.id, arguments: retry)
        do { _ = try await core.reviewAction(task.id, arguments: retry); Issue.record("Retried the same Pipelines attempt twice") } catch {}
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "ci-retried").path))
        _ = try await core.reviewAction(task.id, arguments: .object(["action": .string("finish")]))
        try FileManager.default.removeItem(at: f.control.appending(path: "ci-failed"))

        // General, inline and task feedback is repaired, answered exactly once, and resolved.
        try "[{\"id\":101,\"body\":\"Use blue for this existing requirement.\"}]".write(to: f.control.appending(path: "review-feedback"), atomically: true, encoding: .utf8)
        try f.marker("thread-feedback"); try f.marker("bb-task"); try f.marker("lose-reply-response"); try f.marker("hosted-feedback"); try f.marker("pr-revision")
        await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        await core.tick()
        try await f.wait("Bitbucket repair and replies") { try f.store.get(WorkTask.self, task.id).state == .inPR && f.store.session(for: task.id).status == "idle" && FileManager.default.fileExists(atPath: f.control.appending(path: "posted-replies").path) }
        await core.pollPR(task.id) // Recover the reply whose response was lost; never duplicate it.
        let posts = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: "posted-replies"))).array
        #expect(posts.count == 3)
        #expect(posts.allSatisfy { $0["body"].string?.contains("[//]: # (review-response:") == true && $0["body"].string?.contains("<!--") == false })
        #expect(posts.contains { $0["parent"].int == 102 } && posts.contains { $0["parent"].int == 101 })
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "thread-resolved").path))
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "task-resolved").path))

        // Bitbucket does not enforce requested changes; Build Mate must.
        let current = try f.store.get(WorkTask.self, task.id)
        try f.marker("merge-ready"); try f.marker("bb-changes-requested")
        let blocked = try await Bitbucket(runner: f.runner, root: f.store.root).status(task: current, project: f.project)
        #expect(blocked.reviewDecision == "CHANGES_REQUESTED" && blocked.feedback.contains { $0.id.hasPrefix("review:") })
        #expect(blocked.head.count == 40)
        try FileManager.default.removeItem(at: f.control.appending(path: "bb-changes-requested"))

        // An open PR task withholds the merge even though Bitbucket would allow it.
        try FileManager.default.removeItem(at: f.control.appending(path: "task-resolved"))
        await core.pollPR(task.id)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        #expect(await core.backgroundIssues.values.contains { $0.message.contains("open pull request task") })
        try f.marker("task-resolved")

        // A project override the repository forbids withholds the merge; the repository default is used otherwise.
        f.project.settings.mergeStrategy = .rebase; try f.marker("no-fast-forward"); try f.store.save(f.project)
        await core.pollPR(task.id)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        #expect(await core.backgroundIssues.values.contains { $0.message.contains("Settings") })
        f.project.settings.mergeStrategy = nil; try f.store.save(f.project)
        await core.pollPR(task.id)
        #expect(try String(contentsOf: f.control.appending(path: "merge-requested"), encoding: .utf8) == "squash")
        await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .done)
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "gh-calls.jsonl").path))
        await core.shutdown(); try f.cleanup()
    }
}
