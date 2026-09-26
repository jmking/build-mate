import Foundation
import Testing

@Suite(.serialized)
struct ProjectChatTests {
    // Catches duplicate creation, dependency loss, cross-project edits, clone writes and lost chat context after restart.
    @Test func projectChatProposesRoutesRefinesAndResumesWithoutEditingTheClone() async throws {
        var f = try await CoreTests.Fixture()
        var settings = try f.store.settings(); settings.agentsAtOnce = 1; try f.store.saveSettings(settings)
        let core = Orchestrator(store: f.store, runner: f.runner)
        try await core.sendProjectMessage(f.project.id, text: "Plan account search")
        try await f.wait("project proposal and final response") { try f.store.all(Proposal.self).count == 1 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let session = try f.store.session(for: f.project.id, ownerType: "project")
        let thread = try #require(session.codexThreadId)
        let proposal = try #require(f.store.all(Proposal.self).first)
        #expect(try f.store.all(WorkTask.self).isEmpty)
        #expect(try f.store.all(Message.self).filter { $0.sessionId == session.id && $0.body.hasPrefix("Here are three") }.count == 1)
        do { _ = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [1], queue: []); Issue.record("Allowed a task without its selected dependency") } catch {}
        do { _ = try await core.acceptProposal(proposal.id, projectID: UUID(), selected: [0,1,2], queue: []); Issue.record("Allowed cross-project proposal acceptance") } catch {}
        let tasks = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0,1,2], queue: [])
        _ = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0,1,2], queue: [])
        #expect(try f.store.all(WorkTask.self).count == 3)
        #expect(tasks.allSatisfy { $0.state == .backlog && $0.worktreePath == nil && $0.origin == "chat" })
        #expect(tasks[1].dependsOn == [tasks[0].id])
        try await core.sendProjectMessage(f.project.id, text: "Refine task \(tasks[0].id)")
        try await f.wait("refined description") { try f.store.get(WorkTask.self, tasks[0].id).description.contains("active accounts") && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        try await core.sendProjectMessage(f.project.id, text: "Ask a question")
        try await f.wait("project question") { try f.store.session(for: f.project.id, ownerType: "project").status == "waiting" }
        let model = await AppModel(store: f.store, runner: f.runner)
        await model.refresh()
        #expect(await model.needsCount == 1)
        let question = try #require(f.store.all(Message.self).last { $0.kind == "question" })
        try await core.answerProjectQuestion(question.id, projectID: f.project.id, answer: "Active")
        try await f.wait("answer delivered") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        await core.shutdown()
        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        try await resumed.recover()
        try await resumed.sendProjectMessage(f.project.id, text: "Plan more account work")
        try await f.wait("second proposal after restart") { try f.store.all(Proposal.self).count == 2 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        #expect(try f.store.session(for: f.project.id, ownerType: "project").codexThreadId == thread)
        try await resumed.sendProjectMessage(f.project.id, text: "Start the first two now, backlog the rest")
        try await f.wait("mixed creation") { try f.store.all(WorkTask.self).count == 6 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let routed = try f.store.all(WorkTask.self).sorted { $0.number < $1.number }.suffix(3)
        #expect(routed.map(\.state) == [.todo, .todo, .backlog])
        #expect(routed.dropFirst().first?.dependsOn == [routed.first!.id])
        // Pause prevents both task dispatch and project inference; resume and process failure retain the same thread.
        f.project.paused = true; try f.store.save(f.project)
        try await resumed.sendProjectMessage(f.project.id, text: "Status")
        #expect(try f.store.session(for: f.project.id, ownerType: "project").status == "queued")
        try f.marker("chat-crash-once")
        f.project.paused = false; try f.store.save(f.project)
        await resumed.tick()
        try await f.wait("visible chat failure") { try f.store.session(for: f.project.id, ownerType: "project").status == "failed" }
        try await resumed.retryProjectChat(f.project.id)
        try await f.wait("retry with retained context") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        #expect(try f.store.session(for: f.project.id, ownerType: "project").codexThreadId == thread)
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appending(path: "WORKFLOW.md").path))
        #expect(try f.store.all(WorkTask.self).filter { $0.state == .backlog }.allSatisfy { $0.worktreePath == nil })
        await resumed.shutdown()
        try f.cleanup()
    }
}
