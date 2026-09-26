import Foundation
import AVFoundation

struct ProofSubmission: Sendable {
    let summary: String
    let needsRecording: Bool
    let rationale: String
    let checks: [CheckDefinition]
    let recordingCommand: String?

    init(_ arguments: JSON) throws {
        // Older durable Codex threads retain the original summary-only tool schema.
        var report = arguments
        if arguments["needsRecording"].bool == nil, let text = arguments["summary"].string,
           let decoded = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) { report = decoded }
        guard let summary = report["summary"].string, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let visual = report["needsRecording"].bool,
              let rationale = report["rationale"].string, !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .array(let checks) = report["checks"] else {
            throw CoreError.invalid("Provide summary, needsRecording, rationale, checks [{name, command}], and recordingCommand when visual evidence is required. If your tool only accepts summary, encode this report as JSON in summary.")
        }
        self.summary = summary; self.needsRecording = visual; self.rationale = rationale
        self.checks = try checks.map { check in
            guard let name = check["name"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let command = check["command"].string, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreError.invalid("Each proof check needs a name and executable command.")
            }
            return CheckDefinition(name: name, command: command)
        }
        recordingCommand = report["recordingCommand"].string
    }
}

struct ProofRunner: Sendable {
    let store: Store
    let runner: ProcessRunner

    func run(task: WorkTask, project: Project, submission: ProofSubmission) async throws -> Proof {
        guard let cwd = task.worktreePath else { throw CoreError.invalid("Missing worktree") }
        let directory = store.root.appending(path: "projects/\(project.id)/media/\(task.id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logs = store.root.appending(path: "logs/\(task.id)/\(UUID())")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var proof = try store.all(Proof.self).first { $0.taskId == task.id } ?? Proof(taskId: task.id, summary: submission.summary)
        proof.files = 0; proof.additions = 0; proof.deletions = 0
        proof.summary = submission.summary; proof.checks = []; proof.recordingPath = nil; proof.recordingDuration = nil
        proof.rationale = submission.rationale
        proof.recordingRequired = task.proofRequirement == .checksAndRecording || (task.proofRequirement == .automatic && submission.needsRecording)
        let checks = project.settings.checks + submission.checks
        proof.complete = checks.contains { $0.required }
        for (index, check) in checks.enumerated() {
            let started = Date()
            let log = logs.appending(path: "check-\(index).log")
            do {
                let result = try await runCommand(check.command, cwd: cwd, media: directory, project: project, timeout: Double(project.settings.turnTimeoutMs) / 1000)
                try runner.redacted(result.output).write(to: log, atomically: true, encoding: .utf8)
                proof.checks.append(CheckResult(name: check.name, status: result.status == 0 ? "passed" : "failed", durationSec: Date().timeIntervalSince(started), logPath: log.path))
                if check.required && result.status != 0 { proof.complete = false }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try runner.redacted(error.localizedDescription).write(to: log, atomically: true, encoding: .utf8)
                proof.checks.append(CheckResult(name: check.name, status: "failed", durationSec: Date().timeIntervalSince(started), logPath: log.path))
                if check.required { proof.complete = false }
            }
        }
        let command = project.settings.recordingCommand ?? submission.recordingCommand
        if proof.recordingRequired, let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = directory.appending(path: "recording-\(UUID()).mp4")
            let log = logs.appending(path: "recording.log")
            do {
                let result = try await runCommand(command, cwd: cwd, media: directory, project: project, timeout: 180, environment: ["BUILD_MATE_RECORDING_PATH": path.path])
                try runner.redacted(result.output).write(to: log, atomically: true, encoding: .utf8)
                guard result.status == 0 else { throw CoreError.invalid("Recording command failed") }
                let asset = AVURLAsset(url: path)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration > 0, duration <= 180, !tracks.isEmpty else { throw CoreError.invalid("Invalid recording") }
                proof.recordingPath = path.path; proof.recordingDuration = duration
            } catch is CancellationError { throw CancellationError() }
            catch {
                proof.complete = false
                if !FileManager.default.fileExists(atPath: log.path) {
                    try runner.redacted(error.localizedDescription).write(to: log, atomically: true, encoding: .utf8)
                }
            }
        } else if proof.recordingRequired { proof.complete = false }
        let diff = try await runner.run("git", ["diff", "--numstat", "\(project.defaultBranch)...HEAD"], cwd: cwd)
        for line in diff.output.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3 else { continue }
            proof.files += 1; proof.additions += Int(fields[0]) ?? 0; proof.deletions += Int(fields[1]) ?? 0
        }
        let status = try await runner.run("git", ["status", "--porcelain"], cwd: cwd)
        if !status.output.isEmpty { proof.complete = false }
        proof.producedAt = Date()
        try store.save(proof)
        return proof
    }

    private func runCommand(_ command: String, cwd: String, media: URL, project: Project, timeout: Double,
                            environment: [String: String] = [:]) async throws -> CommandResult {
        let temporary = media.appending(path: "tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        func canonicalPath(_ url: URL) throws -> String {
            // Foundation intentionally preserves /var aliases; Seatbelt matches /private/var.
            guard let path = realpath(url.path, nil) else { throw CoreError.invalid("Proof directory is unavailable") }
            defer { free(path) }
            return String(cString: path)
        }
        // Agent-proposed proof commands must not bypass the coding agent's write boundary.
        let profile = "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath (param \"WORKTREE\")) (subpath (param \"MEDIA\")) (literal \"/dev/null\"))" + (project.settings.network ? "" : "(deny network*)")
        return try await runner.run("/usr/bin/sandbox-exec", ["-p", profile,
            "-D", "WORKTREE=" + canonicalPath(URL(fileURLWithPath: cwd)),
            "-D", "MEDIA=" + canonicalPath(media), "/bin/zsh", "-c", command],
            cwd: cwd, timeout: timeout,
            extraEnvironment: environment.merging(["TMPDIR": temporary.path + "/"]) { _, new in new }, allowFailure: true, captureErrors: true)
    }
}
