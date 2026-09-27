import Foundation
import Testing

@Suite(.serialized)
struct ProjectChatTests {
    // Catches duplicate creation, dependency loss, cross-project edits, clone writes and lost chat context after restart.
    @Test func projectChatProposesRoutesRefinesAndResumesWithoutEditingTheClone() async throws {
        var f = try await CoreTests.Fixture()
        var settings = try f.store.settings(); settings.agentsAtOnce = 1; try f.store.saveSettings(settings)
        let core = Orchestrator(store: f.store, runner: f.runner)
        try f.store.saveInstructions("GLOBAL instruction marker", projectID: nil)
        try f.store.saveInstructions("PROJECT instruction marker", projectID: f.project.id)
        let reference = f.root.appending(path: "requirements.txt")
        try "Show empty states clearly.".write(to: reference, atomically: true, encoding: .utf8)
        try await core.sendProjectMessage(f.project.id, text: "Plan account search", files: [f.control.appending(path: "proof.png"), reference])
        let originals = try f.store.all(Attachment.self)
        #expect(originals.count == 2)
        try FileManager.default.removeItem(at: reference)
        #expect(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try await f.wait("project proposal and final response") { try f.store.all(Proposal.self).count == 1 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let session = try f.store.session(for: f.project.id, ownerType: "project")
        let thread = try #require(session.codexThreadId)
        #expect(session.activeModel == "gpt-6-astra" && session.activeEffort == "high")
        let requests = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)
        #expect(requests.contains("GLOBAL instruction marker") && requests.contains("PROJECT instruction marker"))
        try f.store.saveInstructions("UPDATED instruction marker", projectID: f.project.id)
        #expect(try String(contentsOf: f.store.root.appending(path: "projects/\(f.project.id)/WORKFLOW.md"), encoding: .utf8).contains("UPDATED instruction marker"))
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
        #expect(tasks[0].description == proposal.tasks[0].description) // Markdown structure survives proposal acceptance.
        #expect(tasks[0].description.contains("\n\n## Scope\n\n-"))
        #expect(try f.store.all(Attachment.self).filter { $0.ownerType == "task" }.count == 6)
        #expect(try String(contentsOf: f.control.appending(path: "image-inputs.jsonl"), encoding: .utf8).contains("turn/start"))
        let invalid = f.root.appending(path: "broken.png")
        try "not an image".write(to: invalid, atomically: true, encoding: .utf8)
        do { try await core.sendProjectMessage(f.project.id, text: "Invalid reference", files: [f.control.appending(path: "proof.png"), invalid]); Issue.record("Accepted corrupt image after copying a valid attachment") } catch {}
        #expect(try f.store.all(Attachment.self).count == 8)
        try await core.sendProjectMessage(f.project.id, text: "Refine task \(tasks[0].id)")
        try await f.wait("refined description") { try f.store.get(WorkTask.self, tasks[0].id).description.contains("active accounts") && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        try await core.sendProjectMessage(f.project.id, text: "Ask a question")
        try await f.wait("project question") { try f.store.session(for: f.project.id, ownerType: "project").status == "waiting" }
        let model = await AppModel(store: f.store, runner: f.runner)
        await model.refresh()
        #expect(await model.needsCount == 1)
        let question = try #require(f.store.all(Message.self).last { $0.kind == "question" })
        let activeTurn = try f.store.session(for: f.project.id, ownerType: "project").currentTurn
        try await core.setModel(ownerID: f.project.id, projectChat: true, model: "gpt-5.6-luna", effort: "low")
        #expect(try f.store.session(for: f.project.id, ownerType: "project").currentTurn == activeTurn)
        #expect(try f.store.session(for: f.project.id, ownerType: "project").activeModel == "gpt-6-astra")
        try await core.answerProjectQuestion(question.id, projectID: f.project.id, answer: "Active")
        try await f.wait("answer delivered") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        await core.shutdown()
        let resumed = Orchestrator(store: try Store(root: f.store.root), runner: f.runner)
        try await resumed.recover()
        try await resumed.sendProjectMessage(f.project.id, text: "Plan more account work")
        try await f.wait("second proposal after restart") { try f.store.all(Proposal.self).count == 2 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        #expect(try f.store.session(for: f.project.id, ownerType: "project").codexThreadId == thread)
        #expect(try f.store.session(for: f.project.id, ownerType: "project").activeModel == "gpt-5.6-luna")
        #expect(try f.store.session(for: f.project.id, ownerType: "project").activeEffort == "low")
        let turns = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }.filter { $0["method"].string == "turn/start" }
        #expect(turns.last?["params"]["model"].string == "gpt-5.6-luna")
        #expect(turns.last?["params"]["effort"].string == "low")
        try await resumed.sendProjectMessage(f.project.id, text: "Start the first two now, backlog the rest")
        try await f.wait("mixed creation") { try f.store.all(WorkTask.self).count == 6 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let routed = try f.store.all(WorkTask.self).sorted { $0.number < $1.number }.suffix(3)
        #expect(routed.map(\.state) == [.todo, .todo, .backlog])
        #expect(routed.dropFirst().first?.dependsOn == [routed.first!.id])
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("UPDATED instruction marker"))
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
        // Recovery removes merged-task copies but preserves the shared source until every linked task merges.
        var first = try f.store.get(WorkTask.self, tasks[0].id); first.state = .done; try f.store.save(first)
        let cleanup = Orchestrator(store: f.store, runner: f.runner)
        try await cleanup.recover()
        #expect(try f.store.all(Attachment.self).filter { $0.ownerId == first.id }.allSatisfy { $0.removedAt != nil })
        #expect(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        for var task in try f.store.all(WorkTask.self) { task.state = .done; try f.store.save(task) }
        try await cleanup.recover()
        #expect(try f.store.all(Attachment.self).allSatisfy { $0.removedAt != nil })
        #expect(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try f.store.all(Message.self).contains { $0.body == "Plan account search" })
        await cleanup.shutdown()
        try f.marker("no-astra")
        let unavailable = Orchestrator(store: f.store, runner: f.runner)
        _ = try await unavailable.models()
        do { try await unavailable.setModel(ownerID: f.project.id, projectChat: true, model: "gpt-6-astra", effort: "high"); Issue.record("Silently substituted unavailable Astra") } catch {}
        #expect(try f.store.get(AgentConfiguration.self, f.project.id).model == "gpt-5.6-luna")
        await unavailable.shutdown()
        try f.cleanup()
    }
}
