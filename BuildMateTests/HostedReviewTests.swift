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
        try FileManager.default.removeItem(at: f.control.appending(path: "ci-failed"))
        try "[{\"id\":101,\"body\":\"Use blue for this existing requirement.\"}]".write(to: f.control.appending(path: "review-feedback"), atomically: true, encoding: .utf8)
        try f.marker("hosted-feedback"); try f.marker("pr-revision")
        await core.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .building)
        await core.tick()
        try await f.wait("automatic same-PR repair and reply") { try f.store.get(WorkTask.self, task.id).state == .inPR && f.store.session(for: task.id).status == "idle" && FileManager.default.fileExists(atPath: f.control.appending(path: "posted-replies").path) }
        let posts = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: "posted-replies")))
        #expect(posts.array.count == 1)
        #expect(try f.store.all(Proof.self).first?.qaReview != nil)
        await core.shutdown()
        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        try f.marker("merge-ready")
        await resumed.pollPR(task.id)
        let approval = try #require(f.store.all(Approval.self).first { $0.kind == "merge" && $0.status == "pending" })
        #expect(!FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        try await resumed.approveMerge(approval.id)
        #expect(FileManager.default.fileExists(atPath: f.control.appending(path: "merge-requested").path))
        await resumed.pollPR(task.id)
        #expect(try JSONDecoder().decode(JSON.self, from: Data(contentsOf: f.control.appending(path: "posted-replies"))).array.count == 1)
        let calls = try String(contentsOf: f.control.appending(path: "gh-calls.jsonl"), encoding: .utf8)
        let commands = try calls.split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)).array.compactMap(\.string) }
        #expect(commands.filter { $0.prefix(2) == ["pr", "merge"] }.count == 1)
        #expect(calls.contains("--match-head-commit") && !calls.contains("--admin"))
        try f.marker("merged"); await resumed.pollPR(task.id)
        #expect(try f.store.get(WorkTask.self, task.id).state == .done)
        await resumed.shutdown(); try f.cleanup()
    }
}
