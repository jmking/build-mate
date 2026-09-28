import Foundation
import Testing

@Suite(.serialized)
struct AgentApprovalTests {
    @Test func nativeApprovalsWaitForHumanReplyPreserveTheTurnAndExpireOnStop() async throws {
        var f = try await CoreTests.Fixture()
        f.project.settings.turnTimeoutMs = 1500; f.project.settings.stallTimeoutMs = 300; try f.store.save(f.project)
        try f.marker("native-approvals")
        let core = Orchestrator(store: f.store, runner: f.runner)
        let task = try f.store.createTask(projectId: f.project.id, title: "Launch app for QA")
        await core.tick()
        func pending() throws -> [Message] { try f.store.all(Message.self).filter(\.isPendingAgentApproval) }
        func resolvedCount() throws -> Int { try f.store.all(Message.self).filter { $0.kind == "agentApproval" && $0.payload["status"].string == "resolved" }.count }
        // The fixture sends one extra request and immediately resolves it. Wait for that event
        // before capturing cards, rather than racing its transient fifth approval.
        try await f.wait("four native approval cards") { try pending().count == 4 && resolvedCount() == 1 }
        let original = try f.store.session(for: task.id)
        #expect(original.status == "approval")
        #expect(try f.store.all(Message.self).contains { $0.body == "Allow command?" && $0.payload["status"].string == "resolved" })
        #expect(try !pending().contains { $0.payload["details"].string?.contains("do-not-run") == true })
        // Neither stall nor turn timeouts may consume time waiting for a human.
        try await Task.sleep(for: .seconds(2))
        await core.tick()
        #expect(try f.store.session(for: task.id).currentTurn == original.currentTurn)
        let prompts = try pending()
        for message in prompts {
            try await core.resolveAgentApproval(message.id, allow: message.body != "Allow file changes?")
        }
        try await f.wait("all native replies") {
            (try? String(contentsOf: f.control.appending(path: "approval-results.jsonl"), encoding: .utf8).split(separator: "\n").count) == 7
        }
        let results = try String(contentsOf: f.control.appending(path: "approval-results.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
        #expect(results.first { $0["kind"].string == "approval-command" }?["result"]["decision"].string == "accept")
        #expect(results.first { $0["kind"].string == "approval-files" }?["result"]["decision"].string == "decline")
        #expect(results.first { $0["kind"].string == "approval-foreign" }?["result"]["decision"].string == "decline")
        #expect(results.first { $0["kind"].string == "approval-stale" }?["result"]["decision"].string == "decline")
        #expect(results.first { $0["kind"].string == "approval-missing-turn" }?["result"]["decision"].string == "decline")
        let permissions = try #require(results.first { $0["kind"].string == "approval-permissions" })["result"]
        #expect(permissions["scope"].string == "turn" && permissions["permissions"]["network"]["enabled"].bool == true)
        #expect(permissions["permissions"]["fileSystem"]["write"].array == [.string(f.control.appending(path: "qa-cache").path)])
        #expect(results.first { $0["kind"].string == "approval-connector" }?["result"]["action"].string == "accept")
        #expect(try f.store.session(for: task.id).currentTurn == original.currentTurn)
        await #expect(throws: (any Error).self) { try await core.resolveAgentApproval(prompts[0].id, allow: true) }
        try await core.pause(task.id, paused: true)
        try await core.pause(task.id, paused: false)
        try await f.wait("fresh approvals after resume") { try pending().count == 4 && resolvedCount() == 2 }
        let stale = try #require(pending().first)
        try await core.pause(task.id, paused: true)
        #expect(try pending().isEmpty)
        await #expect(throws: (any Error).self) { try await core.resolveAgentApproval(stale.id, allow: true) }
        // Project chat uses the same approval UI/response path, without inheriting full task access.
        f.project.settings.approvalMode = .fullAccess; try f.store.save(f.project)
        try await core.sendProjectMessage(f.project.id, text: "Inspect the preview")
        try await f.wait("project approvals") { try pending().count == 4 && resolvedCount() == 3 }
        let chat = try f.store.session(for: f.project.id, ownerType: "project")
        #expect(try pending().allSatisfy { $0.sessionId == chat.id })
        for prompt in try pending() { try await core.resolveAgentApproval(prompt.id, allow: false) }
        await core.stopProjectChat(f.project.id)
        // Persisted approvals cannot survive loss of their native callback.
        let orphan = Message(sessionId: chat.id, role: "system", kind: "agentApproval", body: "Old approval", payload: .object(["status": .string("pending")]))
        try f.store.save(orphan)
        try await core.recover()
        #expect(try f.store.get(Message.self, orphan.id).payload["status"].string == "expired")
        await core.shutdown(); try f.cleanup()
    }

    @Test func fullAccessAppliesToQACommandsWhileTaskOverridesRestoreTheSandbox() async throws {
        var f = try await CoreTests.Fixture()
        f.project.settings.checks = []; f.project.settings.network = false
        try f.store.save(f.project)
        var task = try f.store.createTask(projectId: f.project.id, title: "QA cache access", proofRequirement: .checksOnly)
        task = try await Workspace(store: f.store, runner: f.runner).prepare(task, project: f.project)
        let marker = f.control.appending(path: "qa-outside-worktree")
        let submission = try ProofSubmission(.object([
            "summary": .string("Validate cache access"), "needsRecording": .bool(false), "rationale": .string("QA needs a cache outside the checkout"),
            "checks": .array([.object(["name": .string("Cache access"), "command": .string("printf checked > \"$BUILD_MATE_FIXTURE/qa-outside-worktree\"")])])
        ]))
        let proofRunner = ProofRunner(store: f.store, runner: f.runner)
        for (projectMode, override, allowed) in [
            (AgentApprovalMode.ask, Optional<AgentApprovalMode>.none, false),
            (.ask, .fullAccess, true), (.fullAccess, nil, true),
            (.fullAccess, .ask, false), (.fullAccess, .autoReview, false)
        ] {
            f.project.settings.approvalMode = projectMode; task.approvalMode = override
            try f.store.save(f.project); try f.store.save(task)
            let proof = try await proofRunner.run(task: task, project: f.project, submission: submission)
            #expect((proof.checks.first?.status == "passed") == allowed)
            #expect(FileManager.default.fileExists(atPath: marker.path) == allowed)
            if allowed { try FileManager.default.removeItem(at: marker) }
        }
        try f.cleanup()
    }

    @Test func approvalModesInheritFromProjectAndChangeLiveWithoutReplacingTheThread() async throws {
        var f = try await CoreTests.Fixture()
        f.project.settings.approvalMode = .autoReview; f.project.settings.stallTimeoutMs = 0; try f.store.save(f.project)
        try f.marker("approval-modes")
        let core = Orchestrator(store: f.store, runner: f.runner)
        let task = try f.store.createTask(projectId: f.project.id, title: "Change permissions while running")
        await core.tick()
        let path = f.control.appending(path: "active-approval-turn.json")
        func active() throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(contentsOf: path)) }
        try await f.wait("project auto-review default") { (try? active()["params"]["approvalsReviewer"].string) == "auto_review" }
        let thread = try active()["thread"].string
        for mode in [AgentApprovalMode.fullAccess, .ask, .autoReview] {
            let previous = try active()["turn"].string
            try await core.setTaskApprovalMode(task.id, mode: mode)
            try await f.wait("new live permissions") { (try? active()["turn"].string) != previous }
            let parameters = try active()["params"]
            let calls = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
            let resumed = try #require(calls.last { $0["method"].string == "thread/resume" })["params"]
            #expect(resumed["sandbox"].string == (mode == .fullAccess ? "danger-full-access" : "workspace-write"))
            #expect(resumed["approvalPolicy"].string == (mode == .fullAccess ? "never" : "on-request"))
            #expect(try active()["thread"].string == thread)
            #expect(parameters["approvalPolicy"].string == (mode == .fullAccess ? "never" : "on-request"))
            #expect(parameters["approvalsReviewer"].string == (mode == .autoReview ? "auto_review" : "user"))
            #expect(parameters["sandboxPolicy"]["type"].string == (mode == .fullAccess ? "dangerFullAccess" : "workspaceWrite"))
            #expect(try Store(root: f.store.root).get(WorkTask.self, task.id).approvalMode == mode)
        }
        try await core.pause(task.id, paused: true)
        try await core.setTaskApprovalMode(task.id, mode: nil)
        #expect(try f.store.get(WorkTask.self, task.id).approvalMode == nil)
        #expect(try f.store.get(WorkTask.self, task.id).paused)
        #expect(try f.store.session(for: task.id).currentTurn == nil)
        await core.shutdown(); try f.cleanup()
    }
}
