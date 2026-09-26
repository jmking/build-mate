import Foundation
import AVFoundation

struct ProofRunner: Sendable {
    let store: Store
    let runner: ProcessRunner

    func run(task: WorkTask, project: Project, summary: String) async throws -> Proof {
        guard let cwd = task.worktreePath else { throw CoreError.invalid("Missing worktree") }
        let directory = store.root.appending(path: "projects/\(project.id)/media/\(task.id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logs = store.root.appending(path: "logs/\(task.id)/\(UUID())")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var proof = try store.all(Proof.self).first { $0.taskId == task.id } ?? Proof(taskId: task.id, summary: summary)
        proof.files = 0; proof.additions = 0; proof.deletions = 0
        proof.summary = summary; proof.complete = true; proof.checks = []; proof.recordingPath = nil
        for (index, check) in project.settings.checks.enumerated() {
            let started = Date()
            let log = logs.appending(path: "check-\(index).log")
            do {
                let result = try await runner.run("/bin/zsh", ["-c", check.command], cwd: cwd, timeout: Double(project.settings.turnTimeoutMs) / 1000, allowFailure: true, captureErrors: true)
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
        if let command = project.settings.recordingCommand {
            let path = directory.appending(path: "recording-\(UUID()).mp4")
            do {
                try await runner.hook(command, cwd: cwd, timeout: 180, environment: ["BUILD_MATE_RECORDING_PATH": path.path])
                let asset = AVURLAsset(url: path)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration > 0, duration <= 180, !tracks.isEmpty else { throw CoreError.invalid("Invalid recording") }
                proof.recordingPath = path.path; proof.recordingDuration = duration
            } catch is CancellationError { throw CancellationError() }
            catch { if project.settings.recordingRequired { proof.complete = false } }
        } else if project.settings.recordingRequired { proof.complete = false }
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
}
