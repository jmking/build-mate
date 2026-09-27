import Foundation
import Darwin

struct PreviewStatus: Sendable {
    let token = UUID()
    let port: Int
    let url: URL
    var phase = "starting"
    var error: String?
    var lastOpened = ContinuousClock.now
    var log = ""
}

extension Orchestrator {
    func startPreview(_ id: UUID, timeout: Double = 90) async throws -> URL {
        guard !shuttingDown, !editingTasks.contains(id) else { throw CoreError.invalid("Wait for the current task action to finish.") }
        if let job = previewJobs[id] { return try await job.value }
        if let status = previews[id], status.phase == "ready", let child = previewProcesses[id] {
            let running = await child.isRunning()
            guard previews[id]?.token == status.token else { return try await startPreview(id, timeout: timeout) }
            if running { previews[id]?.lastOpened = ContinuousClock.now; return status.url }
            await stopPreview(id)
            return try await startPreview(id, timeout: timeout)
        }
        let task = try store.get(WorkTask.self, id)
        let project = try store.project(for: task)
        guard !task.state.terminal, let cwd = task.worktreePath, FileManager.default.fileExists(atPath: cwd) else { throw CoreError.invalid("This task has no available worktree.") }
        let command = project.settings.previewCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw CoreError.invalid("Configure a preview command for this project first.") }
        let variable = project.settings.previewPortEnvVar
        guard variable.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              !["PATH", "HOME", "TMPDIR", "SHELL"].contains(variable) else { throw CoreError.invalid("Use a port variable such as PORT.") }
        let path = project.settings.previewReadyPath
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#") else { throw CoreError.invalid("The ready path must be a local path beginning with /.") }
        guard previewProcesses.count < 2 else { throw CoreError.invalid("Two previews are already running. Stop one before opening another.") }
        let used = Set(previewProcesses.keys.compactMap { previews[$0]?.port })
        guard let port = (4100...4199).first(where: { !used.contains($0) && Self.portAvailable($0) }),
              let url = URL(string: "http://127.0.0.1:\(port)/"),
              let readyURL = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw CoreError.invalid("No preview port is available between 4100 and 4199.") }
        let status = PreviewStatus(port: port, url: url)
        let child = ChildProcess()
        previews[id] = status; previewProcesses[id] = child
        let job = Task<URL, Error> {
            do {
                try Task.checkCancellation()
                try await child.start("/bin/zsh", ["-c", command], cwd: cwd,
                                      environment: runner.environment.merging([variable: String(port), "HOST": "127.0.0.1"]) { _, new in new }, captureErrors: true)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 1
                configuration.timeoutIntervalForResource = 1
                configuration.connectionProxyDictionary = [:]
                let http = URLSession(configuration: configuration)
                defer { http.invalidateAndCancel() }
                let deadline = ContinuousClock.now + .seconds(timeout)
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard previews[id]?.token == status.token else { throw CancellationError() }
                    await collectPreviewLog(id, child: child)
                    guard await child.isRunning() else { throw CoreError.invalid("The preview command exited before it was ready. Check its output.") }
                    if let (_, response) = try? await http.data(from: readyURL), let response = response as? HTTPURLResponse,
                       (200..<400).contains(response.statusCode), response.url?.host == "127.0.0.1", response.url?.port == port {
                        try Task.checkCancellation()
                        guard previews[id]?.token == status.token else { throw CancellationError() }
                        previews[id]?.phase = "ready"
                        previewMonitors[id] = Task {
                            while !Task.isCancelled {
                                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                                guard previews[id]?.token == status.token else { return }
                                await collectPreviewLog(id, child: child)
                                if !(await child.isRunning()) {
                                    var failed = previews[id] ?? status
                                    await stopPreview(id)
                                    if previews[id] == nil {
                                        failed.phase = "failed"; failed.error = "The preview stopped. Check its output or run it again."
                                        previews[id] = failed
                                    }
                                    return
                                }
                                if (previews[id]?.lastOpened ?? status.lastOpened).duration(to: .now) >= .seconds(1800) { await stopPreview(id); return }
                            }
                        }
                        return url
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                throw CoreError.invalid("The preview did not become ready within \(Int(timeout)) seconds. Check the command, port variable and ready path.")
            } catch {
                if previews[id]?.token == status.token {
                    await collectPreviewLog(id, child: child)
                    var failed = previews[id] ?? status
                    await stopPreview(id)
                    if !(error is CancellationError), previews[id] == nil { failed.phase = "failed"; failed.error = runner.redacted(error.localizedDescription); previews[id] = failed }
                } else { await child.stop() }
                throw error
            }
        }
        previewJobs[id] = job
        defer { if previews[id]?.token == status.token { previewJobs[id] = nil } }
        return try await job.value
    }

    func stopPreview(_ id: UUID) async {
        previewJobs.removeValue(forKey: id)?.cancel()
        previewMonitors.removeValue(forKey: id)?.cancel()
        let child = previewProcesses.removeValue(forKey: id)
        previews[id] = nil
        await child?.stop()
    }

    private func collectPreviewLog(_ id: UUID, child: ChildProcess) async {
        let output = runner.redacted(await child.drainOutput())
        guard previewProcesses[id] === child, !output.isEmpty, var status = previews[id] else { return }
        status.log = String((status.log + output).suffix(64_000))
        previews[id] = status
    }

    private static func portAvailable(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
