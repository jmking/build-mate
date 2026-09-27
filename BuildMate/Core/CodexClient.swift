import Foundation

actor CodexClient {
    private let child = ChildProcess()
    private var reader: Task<Void, Never>?
    private var sequence = 0
    private var responses: [Int: JSON] = [:]
    private var events: [JSON] = []
    private var failure: String?
    private(set) var lastEventAt = SuspendingClock.now
    private var timeout: Double = 5
    private var workingDirectory: String?
    private var didReadInheritedConfiguration = false
    private var configuredModel: String?
    private var inheritedEffort: String?
    private var activeCommands: Set<String> = []
    private var activeTurns: [String: String] = [:]
    private var startedSubagentActivities: Set<String> = []
    private var stopping: Task<Void, Never>?

    func start(runner: ProcessRunner, cwd: String, timeout: Double) async throws {
        self.timeout = timeout
        workingDirectory = cwd
        try await child.start("codex", ["app-server"], cwd: cwd, environment: runner.environment)
        reader = Task { [weak self, child] in
            do {
                while !Task.isCancelled {
                    let data = try await child.nextLine(timeout: 86_400)
                    let value = try JSONDecoder().decode(JSON.self, from: data)
                    await self?.receive(value)
                }
            } catch { await self?.failed(error.localizedDescription) }
        }
        _ = try await request("initialize", [
            "clientInfo": .object(["name": .string("build_mate"), "version": .string("0.1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        try await child.write(.object(["method": .string("initialized")]))
    }
    var hasActiveCommands: Bool { !activeCommands.isEmpty }

    /// Keep each conversation's resolved preference separate from the shared model catalogue.
    func inheritedReasoningEffort() async -> String? {
        await readInheritedConfiguration()
        return inheritedEffort
    }
    func inheritedModel() async -> String? {
        await readInheritedConfiguration()
        return configuredModel
    }
    private func readInheritedConfiguration() async {
        if !didReadInheritedConfiguration {
            didReadInheritedConfiguration = true
            var parameters: [String: JSON] = ["includeLayers": .bool(false)]
            if let workingDirectory { parameters["cwd"] = .string(workingDirectory) }
            // Older servers can omit this capability. Never log or retain the full configuration.
            let configuration = try? await request("config/read", parameters)["config"]
            configuredModel = configuration?["model"].string
            inheritedEffort = configuration?["model_reasoning_effort"].string
        }
    }
    private func receive(_ value: JSON) {
        lastEventAt = SuspendingClock.now
        let item = value["params"]["item"]
        if value["method"].string == "item/started", item["type"].string == "subAgentActivity",
           let thread = value["params"]["threadId"].string, let id = item["id"].string {
            let key = thread + ":" + id + ":" + (item["kind"].string ?? "")
            // Replayed interaction notifications must not restart a finished child.
            guard startedSubagentActivities.insert(key).inserted else { return }
        }
        if let thread = value["params"]["threadId"].string, let turn = value["params"]["turn"]["id"].string {
            if value["method"].string == "turn/started" { activeTurns[thread] = turn }
            if value["method"].string == "turn/completed", activeTurns[thread] == turn { activeTurns[thread] = nil }
        }
        if let itemId = value["params"]["item"]["id"].string {
            if value["method"].string == "item/started", value["params"]["item"]["type"].string == "commandExecution" { activeCommands.insert(itemId) }
            if value["method"].string == "item/completed" { activeCommands.remove(itemId) }
        }
        if let id = value["id"].int, value["method"] == .null { responses[id] = value }
        else { events.append(value) }
    }
    private func failed(_ text: String) { failure = text }
    func request(_ method: String, _ parameters: [String: JSON], timeout override: Double? = nil) async throws -> JSON {
        sequence += 1; let id = sequence
        try await child.write(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(parameters)]))
        let deadline = SuspendingClock.now.advanced(by: .seconds(override ?? timeout))
        while true {
            try Task.checkCancellation()
            if let value = responses.removeValue(forKey: id) {
                if value["error"] != .null { throw CoreError.invalid("Codex \(method): \(value["error"]["message"].string ?? "request failed")") }
                return value["result"]
            }
            if let failure { throw CoreError.invalid(failure) }
            guard SuspendingClock.now < deadline else { throw CoreError.invalid("Codex \(method) timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func nextEvent() async throws -> JSON? {
        try Task.checkCancellation()
        if !events.isEmpty { return events.removeFirst() }
        if let failure { throw CoreError.invalid(failure) }
        try await Task.sleep(for: .milliseconds(20))
        return nil
    }
    func respond(_ id: JSON, text: String, success: Bool = true) async throws {
        lastEventAt = SuspendingClock.now // Human/proof waiting is excluded from the stall clock.
        try await child.write(.object(["id": id, "result": .object([
            "contentItems": .array([.object(["type": .string("inputText"), "text": .string(text)])]),
            "success": .bool(success)
        ])]))
    }
    func respondUserInput(_ id: JSON, answers: [String: JSON]) async throws {
        lastEventAt = SuspendingClock.now
        try await child.write(.object(["id": id, "result": .object(["answers": .object(answers)])]))
    }
    func reject(_ id: JSON) async throws {
        try await child.write(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported server request")])]))
    }
    /// Decline supported native request shapes without expanding this chat's permissions.
    /// Diagnostics are fixed text: request arguments can contain secrets or private URLs.
    func rejectRequest(_ event: JSON) async throws -> String? {
        let id = event["id"]
        guard id != .null else { return nil }
        let result: JSON
        let diagnostic: String
        switch event["method"].string {
        case "item/commandExecution/requestApproval":
            result = .object(["decision": .string("decline")])
            diagnostic = "A command required approval that Build Mate cannot request yet, so it was declined."
        case "item/fileChange/requestApproval":
            result = .object(["decision": .string("decline")])
            diagnostic = "A file change required approval that Build Mate cannot request yet, so it was declined."
        case "item/permissions/requestApproval":
            result = .object(["permissions": .object([:]), "scope": .string("turn")])
            diagnostic = "Additional file or network access was declined. Build Mate cannot request broader permissions yet."
        case "mcpServer/elicitation/request":
            result = .object(["action": .string("decline"), "content": .null])
            diagnostic = "A connected tool needed input or confirmation that Build Mate cannot request yet, so it was declined."
        case "execCommandApproval", "applyPatchApproval":
            diagnostic = "An action required approval that Build Mate cannot request yet, so it was declined."
            result = .object(["decision": .object(["denied": .object(["rejection": .string(diagnostic)])])])
        default:
            try await reject(id)
            return nil
        }
        lastEventAt = SuspendingClock.now
        try await child.write(.object(["id": id, "result": result]))
        return diagnostic
    }
    func interrupt(thread: String, turn: String) async {
        let deadline = SuspendingClock.now.advanced(by: .seconds(20))
        while !activeCommands.isEmpty && SuspendingClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = try? await request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: 4)
    }
    func stop() async {
        // Cancellation of the owning task must not skip native child cleanup.
        if let stopping { await stopping.value; return }
        let stopping = Task.detached { await self.stopTurnsAndProcess() }
        self.stopping = stopping
        await stopping.value
    }
    private func stopTurnsAndProcess() async {
        let turns = activeTurns
        await withTaskGroup(of: Void.self) { group in
            for (thread, turn) in turns {
                group.addTask {
                    _ = try? await self.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: 2)
                }
            }
        }
        // Codex can place shell tools in their own process groups. Let its native
        // interruption finish before terminating the app-server's process group.
        let deadline = SuspendingClock.now.advanced(by: .seconds(2))
        while !activeTurns.isEmpty, SuspendingClock.now < deadline, failure == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        reader?.cancel(); reader = nil
        await child.stop()
        activeTurns.removeAll()
    }

}
