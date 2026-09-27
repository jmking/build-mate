import Foundation
import Testing

@Suite(.serialized)
struct ProjectChatTests {
    @Test func intakePreservesExplicitChoicesReferencesAndDependenciesWhenResizingWork() async throws {
        var f = try await CoreTests.Fixture()
        f.project.paused = true; try f.store.save(f.project)
        let core = Orchestrator(store: f.store, runner: f.runner)
        let session = try f.store.session(for: f.project.id, ownerType: "project")
        let message = Message(sessionId: session.id, role: "user", body: "Create a scoped change")
        let references = try f.store.saveChatMessage(message, files: [f.control.appending(path: "proof.png")], projectID: f.project.id, ownerID: f.project.id)
        let item = Proposal.Item(title: "Account search", description: "Search active accounts.", dependsOnIndex: [], attachmentIds: references.map(\.id), model: "gpt-6-astra", effort: "high", modelRationale: "Cross-cutting query and UI requirements.", acceptanceCriteria: ["Inactive accounts never appear."])
        let proposal = try await core.saveProposal(f.project.id, sessionID: session.id, items: [item])
        let original = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0])[0]
        #expect(original.description.contains("## Acceptance criteria"))
        #expect(try f.store.get(AgentConfiguration.self, original.id).recommended)
        try await core.setModel(ownerID: original.id, projectChat: false, model: "gpt-5.6-luna", effort: "low")
        var source = original; source.state = .humanReview; source.paused = true; try f.store.save(source)
        let dependent = WorkTask(projectId: f.project.id, number: 2, title: "Dependent", dependsOn: [source.id])
        try f.store.save(dependent)
        let replacements = try await core.reshapeTasks(projectID: f.project.id, sourceIDs: [source.id], items: [
            Proposal.Item(title: "Query", description: "Search active accounts efficiently.", dependsOnIndex: []),
            Proposal.Item(title: "Search UI", description: "Display query results.", dependsOnIndex: [0])
        ], reason: "Separate query behavior from the independently reviewable UI.")
        #expect(replacements.count == 2 && replacements.allSatisfy(\.paused))
        #expect(try f.store.get(WorkTask.self, source.id).replacedBy == replacements.map(\.id))
        #expect(Set(try f.store.get(WorkTask.self, dependent.id).dependsOn) == Set(replacements.map(\.id)))
        #expect(replacements[1].dependsOn.contains(replacements[0].id))
        for replacement in replacements {
            let config = try f.store.get(AgentConfiguration.self, replacement.id)
            #expect(config.model == "gpt-5.6-luna" && !config.recommended)
            #expect(try f.store.all(Attachment.self).contains { $0.ownerId == replacement.id && $0.sourceAttachmentId != nil })
        }
        let repeated = try await core.reshapeTasks(projectID: f.project.id, sourceIDs: [source.id], items: [item], reason: "retry")
        #expect(repeated.map(\.id) == replacements.map(\.id))
        let updated = try await core.reviseFromProject(replacements[0], title: "Query", description: "Search active accounts with pagination.", attachmentIDs: [])
        #expect(updated.paused && updated.requirementsRevision == 2)
        var merged = updated; merged.state = .done; try f.store.save(merged)
        let followup = try await core.reviseFromProject(merged, title: "Pagination refinement", description: "Retain active-only filtering and add cursor navigation.", attachmentIDs: [])
        #expect(followup.relatedTaskIds == [merged.id] && followup.id != merged.id && followup.state == .todo)
        await core.shutdown(); try f.cleanup()
    }

    // Catches duplicate creation, dependency loss, cross-project edits, clone writes and lost chat context after restart.
    @Test func projectChatQueuesEveryCreatedTaskAndRefinesWithoutEditingTheClone() async throws {
        var f = try await CoreTests.Fixture()
        var settings = try f.store.settings(); settings.agentsAtOnce = 1; try f.store.saveSettings(settings)
        let core = Orchestrator(store: f.store, runner: f.runner)
        try f.marker("subagents")
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
        func turns() throws -> [JSON] {
            try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
                .filter { $0["method"].string == "turn/start" && $0["params"]["threadId"].string == thread }
        }
        func inputText(_ turn: JSON) -> String { turn["params"]["input"].array.compactMap { $0["text"].string }.joined(separator: "\n") }
        #expect(try turns().first?["params"]["input"].array.filter { $0["type"].string == "localImage" }.count == 1)
        try FileManager.default.removeItem(at: f.control.appending(path: "subagents"))
        let delegated = try #require(f.store.all(Subagent.self).first { $0.sessionId == session.id })
        #expect(delegated.parentThreadId == thread && delegated.status == "completed" && delegated.result == "Delegated findings only.")
        #expect(session.turnCount == 1 && session.tokensIn == 11 && session.tokensOut == 7)
        #expect(try !f.store.all(Message.self).contains { $0.body.contains("Delegated findings") || $0.body.contains("FOREIGN") })
        #expect(session.activeModel == "gpt-6-astra" && session.activeEffort == "high")
        let requests = try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8)
        #expect(requests.contains("GLOBAL instruction marker") && requests.contains("PROJECT instruction marker"))
        #expect(requests.contains("Current task guidance (supersedes earlier versions)"))
        try f.store.saveInstructions("UPDATED instruction marker", projectID: f.project.id)
        #expect(try String(contentsOf: f.store.root.appending(path: "projects/\(f.project.id)/WORKFLOW.md"), encoding: .utf8).contains("UPDATED instruction marker"))
        let proposal = try #require(f.store.all(Proposal.self).first)
        #expect(try f.store.all(WorkTask.self).isEmpty)
        #expect(try f.store.all(Message.self).filter { $0.sessionId == session.id && $0.body.hasPrefix("Here are three") }.count == 1)
        // Emoji-only replies become reactions only after completion; text, attachments and history are preserved.
        try await core.sendProjectMessage(f.project.id, text: "Cool")
        try await f.wait("streaming emoji") { try f.store.all(Message.self).contains { $0.body == "👍" && $0.payload["streaming"].bool == true } }
        let streamed = try f.store.all(Message.self).filter { $0.sessionId == session.id }
        let reactedTo = try #require(streamed.last { $0.role == "user" && $0.body == "Cool" })
        #expect(ChatReactions.targets(in: streamed)[reactedTo.id] == nil)
        try f.marker("finish-reaction")
        try await f.wait("completed reaction") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let changedGuidance = inputText(try #require(turns().last))
        #expect(changedGuidance.contains("UPDATED instruction marker") && changedGuidance.contains("Cool"))
        #expect(!changedGuidance.contains("Plan account search") && !changedGuidance.contains("Here are three tasks you can add to Queue."))
        let completed = try Store(root: f.store.root).all(Message.self).filter { $0.sessionId == session.id }
        let reaction = try #require(ChatReactions.targets(in: completed)[reactedTo.id]?.first)
        #expect(reaction.body == "👍🏽")
        #expect(completed.contains { $0.id == reaction.id && $0.body == "👍🏽" })
        #expect(ChatReactions.targets(in: completed, attachmentMessageIDs: [reaction.id])[reactedTo.id] == nil)
        try await core.sendProjectMessage(f.project.id, text: "Emoji with text")
        try await f.wait("emoji followed by prose") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let unchangedGuidance = inputText(try #require(turns().last))
        #expect(unchangedGuidance.contains("Emoji with text") && !unchangedGuidance.contains("UPDATED instruction marker") && !unchangedGuidance.contains("Cool"))
        let withText = try f.store.all(Message.self).filter { $0.sessionId == session.id }
        #expect(withText.contains { $0.body == "👍 Sounds good. I will keep that in mind." })
        #expect(ChatReactions.targets(in: withText).count == 1)
        do { _ = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [1]); Issue.record("Allowed a task without its selected dependency") } catch {}
        do { _ = try await core.acceptProposal(proposal.id, projectID: UUID(), selected: [0,1,2]); Issue.record("Allowed cross-project proposal acceptance") } catch {}
        f.project = try f.store.get(Project.self, f.project.id)
        f.project.paused = true; try f.store.save(f.project)
        let tasks = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0,1,2])
        _ = try await core.acceptProposal(proposal.id, projectID: f.project.id, selected: [0,1,2])
        #expect(try f.store.all(WorkTask.self).count == 3)
        #expect(tasks.allSatisfy { $0.state == .todo && $0.worktreePath == nil && $0.origin == "chat" })
        for var task in tasks { task.paused = true; try f.store.save(task) }
        f.project.paused = false; try f.store.save(f.project)
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
        await core.tick() // A project question releases its process while retaining the question and thread.
        #expect(try f.store.session(for: f.project.id, ownerType: "project").currentTurn == nil)
        #expect(try f.store.session(for: f.project.id, ownerType: "project").status == "waiting")
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
        #expect(try Store(root: f.store.root).get(Subagent.self, delegated.id).result == "Delegated findings only.")
        try await resumed.sendProjectMessage(f.project.id, text: "Plan more account work")
        try await f.wait("second proposal after restart") { try f.store.all(Proposal.self).count == 2 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        #expect(try f.store.session(for: f.project.id, ownerType: "project").codexThreadId == thread)
        #expect(try f.store.session(for: f.project.id, ownerType: "project").activeModel == "gpt-5.6-luna")
        #expect(try f.store.session(for: f.project.id, ownerType: "project").activeEffort == "low")
        let resumedTurn = try #require(turns().last)
        #expect(resumedTurn["params"]["model"].string == "gpt-5.6-luna")
        #expect(resumedTurn["params"]["effort"].string == "low")
        #expect(inputText(resumedTurn).contains("Plan more account work") && !inputText(resumedTurn).contains("Plan account search"))
        #expect(try turns().dropFirst().allSatisfy { !$0["params"]["input"].array.contains { $0["type"].string == "localImage" } })
        try await resumed.sendProjectMessage(f.project.id, text: "Create all three tasks")
        try await f.wait("queued creation") { try f.store.all(WorkTask.self).count == 6 && f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let routed = try f.store.all(WorkTask.self).sorted { $0.number < $1.number }.suffix(3)
        #expect(routed.map(\.state) == [.todo, .todo, .todo])
        for var task in routed { task.paused = true; try f.store.save(task) }
        #expect(routed.dropFirst().first?.dependsOn == [routed.first!.id])
        #expect(try String(contentsOf: f.control.appending(path: "calls.jsonl"), encoding: .utf8).contains("UPDATED instruction marker"))
        // Pause prevents both task dispatch and project inference; resume and process failure retain the same thread.
        f.project.paused = true; try f.store.save(f.project)
        try await resumed.sendProjectMessage(f.project.id, text: "Status")
        #expect(try f.store.session(for: f.project.id, ownerType: "project").status == "queued")
        let acceptedTurns = try f.store.session(for: f.project.id, ownerType: "project").turnCount
        try f.marker("reject-turn-once")
        f.project.paused = false; try f.store.save(f.project)
        await resumed.tick()
        try await f.wait("visible chat failure") { try f.store.session(for: f.project.id, ownerType: "project").status == "failed" }
        #expect(try f.store.session(for: f.project.id, ownerType: "project").turnCount == acceptedTurns)
        try await resumed.retryProjectChat(f.project.id)
        try await f.wait("retry with retained context") { try f.store.session(for: f.project.id, ownerType: "project").status == "idle" }
        let retried = try turns().suffix(2)
        #expect(retried.count == 2 && retried.allSatisfy { inputText($0).contains("New user messages (in order):\nStatus") }) // Failed turn/start must not acknowledge undelivered input.
        #expect(try f.store.session(for: f.project.id, ownerType: "project").turnCount == acceptedTurns + 1)
        #expect(try f.store.session(for: f.project.id, ownerType: "project").codexThreadId == thread)
        #expect(try await f.runner.run("git", ["status", "--porcelain"], cwd: f.repo.path).output.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appending(path: "WORKFLOW.md").path))
        #expect(try f.store.all(WorkTask.self).filter { $0.state == .todo }.allSatisfy { $0.worktreePath == nil })
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
