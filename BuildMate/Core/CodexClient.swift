import Foundation

actor CodexClient {
    private let child = ChildProcess()
    private var reader: Task<Void, Never>?
    private var sequence = 0
    private var responses: [Int: JSON] = [:]
    private var events: [JSON] = []
    private var failure: String?
    private(set) var lastEventAt = Date()
    private var timeout: Double = 5
    private var activeCommands: Set<String> = []

    func start(runner: ProcessRunner, cwd: String, timeout: Double) async throws {
        self.timeout = timeout
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
    private func receive(_ value: JSON) {
        lastEventAt = Date()
        if let itemId = value["params"]["item"]["id"].string {
            if value["method"].string == "item/started", value["params"]["item"]["type"].string == "commandExecution" { activeCommands.insert(itemId) }
            if value["method"].string == "item/completed" { activeCommands.remove(itemId) }
        }
        if let id = value["id"].int, value["method"] == .null { responses[id] = value }
        else { events.append(value) }
    }
    private func failed(_ text: String) { failure = text }
    func request(_ method: String, _ parameters: [String: JSON]) async throws -> JSON {
        sequence += 1; let id = sequence
        try await child.write(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(parameters)]))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let value = responses.removeValue(forKey: id) {
                if value["error"] != .null { throw CoreError.invalid("Codex \(method): \(value["error"]["message"].string ?? "request failed")") }
                return value["result"]
            }
            if let failure { throw CoreError.invalid(failure) }
            guard Date() < deadline else { throw CoreError.invalid("Codex \(method) timed out") }
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
        lastEventAt = Date() // Human/proof waiting is excluded from the stall clock.
        try await child.write(.object(["id": id, "result": .object([
            "contentItems": .array([.object(["type": .string("inputText"), "text": .string(text)])]),
            "success": .bool(success)
        ])]))
    }
    func respondUserInput(_ id: JSON, answers: [String: JSON]) async throws {
        lastEventAt = Date()
        try await child.write(.object(["id": id, "result": .object(["answers": .object(answers)])]))
    }
    func reject(_ id: JSON) async throws {
        try await child.write(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported server request")])]))
    }
    func interrupt(thread: String, turn: String) async {
        let deadline = Date().addingTimeInterval(24)
        while !activeCommands.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = try? await request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
    }
    func stop() async { reader?.cancel(); reader = nil; await child.stop() }

    static let tools: JSON = .array([
        tool("ask_question", "Ask the user before making an unclear decision. Blocking questions wait for an answer.",
             ["prompt": "string", "allowsFreeText": "boolean", "blocking": "boolean"], required: ["prompt", "blocking"], options: true),
        tool("submit_plan", "Submit your plan before editing. Wait for approval when required.", ["plan": "string"], required: ["plan"]),
        tool("request_review", "Request human review after implementation. The app independently runs proof. Do not push or open a PR.", ["summary": "string"], required: ["summary"]),
        tool("note", "Record a short progress note.", ["text": "string"], required: ["text"])
    ])
    private static func tool(_ name: String, _ description: String, _ fields: [String: String], required: [String], options: Bool = false) -> JSON {
        var properties = fields.mapValues { JSON.object(["type": .string($0)]) }
        if options { properties["options"] = .object(["type": .string("array"), "items": .object(["type": .string("string")])]) }
        return .object(["name": .string(name), "description": .string(description), "inputSchema": .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)
        ])])
    }
}
