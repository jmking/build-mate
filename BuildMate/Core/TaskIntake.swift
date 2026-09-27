import Foundation
import GRDB

extension Orchestrator {
    func reviseFromProject(_ original: WorkTask, title: String, description: String, attachmentIDs: [UUID]) async throws -> WorkTask {
        let session = try store.session(for: original.projectId, ownerType: "project")
        let sources = try store.chatAttachments(sessionID: session.id).filter { attachmentIDs.contains($0.id) && $0.removedAt == nil }
        guard Set(sources.map(\.id)) == Set(attachmentIDs) else { throw CoreError.invalid("A reference is no longer available in this project chat.") }
        let project = try store.get(Project.self, original.projectId)
        let mergedRemotely = original.pr != nil && project.host == .github ? try await GitHub(runner: runner, root: store.root).status(task: original, project: project).state == "MERGED" : false
        if original.state.terminal || mergedRemotely {
            let item = Proposal.Item(title: title, description: description, dependsOnIndex: [], attachmentIds: attachmentIDs)
            let proposal = try saveProposal(original.projectId, sessionID: session.id, items: [item])
            return try await acceptProposal(proposal.id, projectID: original.projectId, selected: [0], related: [original.id])[0]
        }
        // Attach before resuming so the first revised turn sees the new references.
        let existing = try store.all(Attachment.self).filter { $0.ownerType == "task" && $0.ownerId == original.id }.compactMap(\.sourceAttachmentId)
        let newSources = sources.filter { !existing.contains($0.id) }
        let copies = try store.prepareAttachments(newSources.map { URL(fileURLWithPath: $0.path) }, projectID: original.projectId, ownerID: original.id, messageID: original.id)
        do {
            try await store.db.write { db in
                for (source, copy) in zip(newSources, copies) {
                    var attachment = copy; attachment.ownerType = "task"; attachment.ownerId = original.id
                    attachment.sourceAttachmentId = source.id; attachment.filename = source.filename; try attachment.insert(db)
                }
            }
        } catch { store.discardPreparedAttachments(copies); throw error }
        try await editTask(original.id, title: title, description: description, proofRequirement: original.proofRequirement, automaticallyResume: true, forceRevision: !newSources.isEmpty)
        return try store.get(WorkTask.self, original.id)
    }

    func reshapeTasks(projectID: UUID, sourceIDs: [UUID], items: [Proposal.Item], reason: String) async throws -> [WorkTask] {
        let sources = try Set(sourceIDs).map { try store.get(WorkTask.self, $0) }.sorted { $0.number < $1.number }
        if let first = sources.first, !first.replacedBy.isEmpty, sources.allSatisfy({ $0.replacedBy == first.replacedBy }) {
            return try first.replacedBy.map { try store.get(WorkTask.self, $0) }
        }
        guard !sources.isEmpty, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sources.allSatisfy({ $0.projectId == projectID && $0.pr == nil && !$0.state.terminal && !editingTasks.contains($0.id) }) else {
            throw CoreError.invalid("Select unpublished tasks in this project and explain how their scope is being reorganized. Published work must be revised on its existing PR.")
        }
        // Do not carry an ambiguous explicit model override into combined work.
        let choices = try sources.compactMap { source in try store.all(AgentConfiguration.self).first { $0.id == source.id && !$0.recommended } }
        guard Set(choices.map { $0.model + ":" + ($0.effort ?? "") }).count <= 1 else { throw CoreError.invalid("These tasks have different explicit model choices. Ask the user which to preserve before combining them.") }
        for source in sources { editingTasks.insert(source.id) }
        defer { for source in sources { editingTasks.remove(source.id) } }
        for source in sources { await stopForReshape(source.id) }
        let references = sources.map { source in
            "- Task #\(source.number): \(source.title)\n  Preserved worktree: \(source.worktreePath ?? "not started"); branch: \(source.branchName ?? "none").\n  Original requirements:\n\(source.description)"
        }.joined(separator: "\n\n")
        var items = items
        for index in items.indices {
            items[index].description += "\n\n## Source work\n\n\(reason)\n\nReuse relevant implementation from these preserved worktrees/branches; do not modify their checkouts. Each replacement implements only its own scope.\n\n\(references)"
            if let choice = choices.first { items[index].model = choice.model; items[index].effort = choice.effort; items[index].modelRationale = "Preserved explicit model choice from source work." }
        }
        let session = try store.session(for: projectID, ownerType: "project")
        let proposal = try saveProposal(projectID, sessionID: session.id, items: items)
        let tasks = try await acceptProposal(proposal.id, projectID: projectID, selected: Set(items.indices), replacing: sources, dispatch: false)
        for source in sources { editingTasks.remove(source.id) }
        await tick()
        return tasks
    }
}
