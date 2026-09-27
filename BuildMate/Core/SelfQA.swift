import Foundation

extension Orchestrator {
    static let qaInstructions = """
    request_review executes checks and captures evidence; it does NOT finish QA. Inspect the returned logs, actual before/after images and recording (use video tools or extract representative frames and inspect them). Verify behavior and acceptance criteria, including failure/empty states and relevant accessibility/appearance modes. A valid media file alone proves nothing. Never describe a static fixture as a live behavioral test. Fix defects and rerun evidence after changes. For risky concurrency, security, architecture or a large change, use an independent native Codex reviewer when available and resolve its findings; skip redundant delegation for bounded changes. Once satisfied, call complete_qa with the returned proofToken, a concise evidence-based assessment, and inspectedPaths containing every returned evidence path. If this older thread lacks complete_qa, call note with text containing exactly 'BUILD_MATE_QA ' followed by a JSON object with those same fields. Disclose limitations; ask a blocking question if a required outcome cannot be verified. Do not claim inspection you did not perform.
    """

    func completeQA(taskID: UUID, arguments: JSON) async throws {
        let task = try store.get(WorkTask.self, taskID)
        guard task.state == .building, !task.paused, let cwd = task.worktreePath,
              var proof = try store.all(Proof.self).first(where: { $0.taskId == taskID }),
              let token = proof.qaToken, arguments["proofToken"].string == token,
              let assessment = arguments["assessment"].string, !assessment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalid("Run current evidence and inspect it before completing QA.")
        }
        let required = Set(proof.evidencePaths)
        let inspected = Set(arguments["inspectedPaths"].array.compactMap(\.string))
        guard required == inspected, required.allSatisfy({ FileManager.default.fileExists(atPath: $0) }),
              proof.requirementsRevision == task.requirementsRevision else { throw CoreError.invalid("Inspect all current evidence paths and verify the current requirements.") }
        let head = try await runner.run("git", ["rev-parse", "HEAD"], cwd: cwd).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proof.commitSHA == head, try await runner.run("git", ["status", "--porcelain"], cwd: cwd).output.isEmpty,
              try store.get(WorkTask.self, taskID).requirementsRevision == proof.requirementsRevision else { throw CoreError.invalid("The work changed after evidence was collected. Run and inspect fresh evidence.") }
        let hosted = try watch(taskID)
        if hosted.repairing {
            guard hosted.feedback.filter({ $0.id.hasPrefix("comment:") || $0.id.hasPrefix("thread:") || $0.id.hasPrefix("review:") }).allSatisfy({ hosted.replies[$0.id] != nil }) else { throw CoreError.invalid("Queue a response to each reviewer before completing this review pass.") }
        }
        proof.qaReview = runner.redacted(assessment); proof.complete = true; try store.save(proof)
        let session = try store.session(for: taskID)
        try store.save(Message(sessionId: session.id, role: "system", kind: "event", body: "Self-review completed. Ready for review."))
        try transition(taskID, to: .humanReview)
        let project = try store.get(Project.self, task.projectId)
        if ((hosted.repairing && hosted.requirementsRevision == task.requirementsRevision) || !project.settings.askBeforeOpenPR) && project.host != .local { try await openPullRequest(taskID) }
    }
}

extension Proof {
    var evidencePaths: [String] { checks.compactMap(\.logPath) + screenshots + (recordingPath.map { [$0] } ?? []) }
}
