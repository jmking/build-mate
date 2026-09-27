import Foundation
import Darwin

struct CommandResult: Sendable { var output: String; var status: Int32 }

/// One child process, drained continuously so large stdout never blocks the child.
actor ChildProcess {
    private var pid: pid_t = 0
    private var exitStatus: Int32?
    private let input = Pipe()
    private let output = Pipe()
    private var bytes = Data()
    private var eof = false
    private var pump: Task<Void, Never>?

    func start(_ executable: String, _ arguments: [String], cwd: String?, environment: [String: String], captureErrors: Bool = false) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        if captureErrors { posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO) }
        else { posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) }
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        // A private process group lets timeout/cancel stop hook grandchildren as well.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = (["/usr/bin/env", executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() }
            else { continuation.yield(data) }
        }
        var childPID: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&childPID, "/usr/bin/env", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else {
            output.fileHandleForReading.readabilityHandler = nil
            throw CoreError.invalid("Unable to start CLI: \(String(cString: strerror(result)))")
        }
        pid = childPID
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        pump = Task { [weak self] in
            for await data in stream { await self?.append(data) }
            await self?.ended()
        }
    }
    private func append(_ data: Data) { bytes.append(data) }
    private func ended() { eof = true }
    func write(_ json: JSON) throws {
        guard isRunning() else { throw CoreError.invalid("CLI process exited") }
        var data = try JSONEncoder().encode(json); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func nextLine(timeout: Double) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let end = bytes.firstIndex(of: 10) {
                let line = bytes.prefix(upTo: end); bytes.removeSubrange(...end)
                return Data(line)
            }
            if eof { throw CoreError.invalid("CLI process closed stdout") }
            if Date() >= deadline { throw CoreError.invalid("CLI read timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func collect(timeout: Double) async throws -> CommandResult {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while isRunning() || !eof {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CoreError.invalid("Command timed out") }
                try await Task.sleep(for: .milliseconds(20))
            }
            return CommandResult(output: String(decoding: bytes, as: UTF8.self), status: exitStatus ?? -1)
        } catch { await stop(); throw error }
    }
    func drainOutput() -> String {
        defer { bytes.removeAll(keepingCapacity: true) }
        return String(decoding: bytes, as: UTF8.self)
    }
    func isRunning() -> Bool {
        guard pid > 0, exitStatus == nil else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        return exitStatus == nil
    }
    func stop() async {
        guard pid > 0 else { return }
        // Kill the group even if its leader exited but left descendants holding stdout.
        kill(-pid, SIGTERM)
        for _ in 0..<20 {
            if !isRunning() && kill(-pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        kill(-pid, SIGKILL)
        // A single WNOHANG check can run before SIGKILL takes effect and leave a
        // zombie forever. Reap our direct child before reporting shutdown complete.
        if exitStatus == nil, kill(pid, SIGKILL) == 0 || errno == ESRCH {
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result < 0 && errno == EINTR { result = waitpid(pid, &status, 0) }
            if result == pid { exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        }
        output.fileHandleForReading.readabilityHandler = nil
        pump?.cancel(); pump = nil
        try? input.fileHandleForWriting.close()
    }

}

struct ProcessRunner: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment.merging([
        "PATH": (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
    ]) { _, new in new }

    func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
             timeout: Double = 60, extraEnvironment: [String: String] = [:], allowFailure: Bool = false, captureErrors: Bool = false) async throws -> CommandResult {
        let child = ChildProcess()
        try await child.start(executable, arguments, cwd: cwd, environment: environment.merging(extraEnvironment) { _, new in new }, captureErrors: captureErrors)
        let result = try await child.collect(timeout: timeout)
        await child.stop()
        guard allowFailure || result.status == 0 else { throw CoreError.invalid("\(executable) exited with status \(result.status)") }
        return result
    }
    func hook(_ command: String, cwd: String, timeout: Double = 60, environment: [String: String] = [:]) async throws {
        guard !command.isEmpty else { return }
        _ = try await run("/bin/zsh", ["-c", command], cwd: cwd, timeout: timeout, extraEnvironment: environment, captureErrors: true)
    }
    func redacted(_ text: String) -> String {
        var result = text
        for (name, value) in environment where value.count >= 4 && name.range(of: "TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL", options: .regularExpression) != nil {
            result = result.replacingOccurrences(of: value, with: "[REDACTED]")
        }
        return result.replacingOccurrences(of: "(?i)(bearer\\s+|(?:token|password|secret|api_key)\\s*[=:]\\s*)[^\\s]+", with: "$1[REDACTED]", options: .regularExpression)
    }
}
