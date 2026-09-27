import Foundation

/// Only installed integrations belong here. Adding a provider requires its runner and contract tests.
enum AgentProvider: String, Codable, CaseIterable, Sendable { case codex }

struct AgentAccess: Sendable {
    var writableRoots: [String] = []
    var network = false
    var isReadOnly: Bool { writableRoots.isEmpty }
}

struct AgentQuestion: Sendable {
    var id: String
    var prompt: String
    var options: [String]
    var allowsFreeText: Bool
    var blocking: Bool
    var secret: Bool
}

enum AgentReply: Sendable {
    case tool(String, success: Bool)
    case answers([String: String])
}

/// The reply closure belongs to the transport. Acknowledgements happen only after it succeeds.
struct AgentRequest: Sendable {
    var name: String?
    var arguments: JSON = .null
    var questions: [AgentQuestion]?
    var reply: @Sendable (AgentReply) async throws -> Void

    func respond(_ text: String, success: Bool = true) async throws { try await reply(.tool(text, success: success)) }
}

struct AgentChild: Sendable {
    var id: String
    var parentID: String
    var name: String?
    var fallbackName: String? = nil
    var prompt: String?
    var model: String?
    var effort: String?
    var status: String?
    var result: String?
    var allowsDiscovery = true
}

enum AgentActivity: Sendable { case command, fileChange, tool, webSearch, other }

struct AgentEvent: Sendable {
    var sessionID: String?
    var turnID: String?
    var kind: Kind
    enum Kind: Sendable {
        case request(AgentRequest)
        case message(id: String?, text: String?, complete: Bool)
        case activity(kind: AgentActivity, command: String?, output: String?)
        case image(id: String?, path: String?, complete: Bool)
        case tokens(input: Int?, output: Int?)
        case usage(AgentUsageUpdate)
        case children([AgentChild])
        case childActivity(id: String, name: String?, status: String?, started: Bool)
        case turnStarted(String?)
        case turnCompleted(String)
        case threadStatus(String?)
        case threadClosed
        case diagnostic(String)
        case ignored
    }
}

/// The workflow owns state, persistence and policy; the runner owns wire formats and native sessions.
protocol AgentRunner: Actor {
    var provider: AgentProvider { get }
    var lastEventAt: SuspendingClock.Instant { get }
    var hasActiveCommands: Bool { get }
    func start(runner: ProcessRunner, cwd: String, timeout: Double) async throws
    func models() async throws -> [AgentModel]
    func suggestTitle(_ description: String, cwd: String) async throws -> String
    func inheritedModel() async -> String?
    func inheritedReasoningEffort() async -> String?
    func openSession(id: String?, cwd: String, model: String, instructions: String, tools: JSON, access: AgentAccess) async throws -> String
    func startTurn(session: String, cwd: String, text: String, attachments: [Attachment], model: String, effort: String?, access: AgentAccess) async throws -> String
    func steer(session: String, turn: String, text: String, attachments: [Attachment]) async throws
    func nextAgentEvent() async throws -> AgentEvent?
    func childDetails(_ id: String, parent: String) async throws -> AgentChild
    func readUsage() async throws -> AgentUsageUpdate
    func interrupt(thread: String, turn: String) async
    func stop() async
}

extension AgentProvider {
    func makeRunner() -> any AgentRunner {
        switch self { case .codex: CodexClient() }
    }
}
