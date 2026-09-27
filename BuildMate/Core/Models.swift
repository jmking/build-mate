import Foundation
import GRDB

enum Host: String, Codable, Sendable {
    case local, github, bitbucket
    var title: String {
        switch self { case .local: "Local Git"; case .github: "GitHub"; case .bitbucket: "Bitbucket Cloud" }
    }
}
enum TaskState: String, Codable, CaseIterable, Sendable {
    case todo, needsClarification = "needs_clarification", building
    case humanReview = "human_review", inPR = "in_pr", done, canceled
    var terminal: Bool { self == .done || self == .canceled }
}

enum ProofRequirement: String, Codable, CaseIterable, Sendable {
    case automatic, checksOnly, checksAndRecording
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .checksOnly: "Checks only"
        case .checksAndRecording: "Checks + recording"
        }
    }
}

struct ProjectSettings: Codable, Sendable {
    var retryBackoffMaxMs = 300_000
    var turnTimeoutMs = 3_600_000
    var stallTimeoutMs = 300_000
    var readTimeoutMs = 5_000
    var askBeforeBuild = false
    var askBeforeOpenPR = true
    var askBeforeMerge = false
    var branchPrefix = ""
    var editor: String?
    var hooks = Hooks()
    var checks: [CheckDefinition] = []
    var recordingCommand: String?
    var screenshotsForUI = true
    var previewCommand = ""
    var previewPortEnvVar = "PORT"
    var previewReadyPath = "/"
    var network = true
    var model: String?
    var effort: String?
}
extension ProjectSettings {
    func validate() throws {
        guard retryBackoffMaxMs > 0, turnTimeoutMs > 0, readTimeoutMs > 0, stallTimeoutMs >= 0,
              hooks.timeoutSeconds.isFinite, hooks.timeoutSeconds > 0 else {
            throw CoreError.invalid("Retry limits and timeouts must be positive")
        }
    }
}
extension Project {
    var runBlockReason: String? {
        if host == .bitbucket { return "Bitbucket task runs are not available yet." }
        return nil
    }
}

enum MessageDelivery: Sendable { case sent, saved, queued }

struct AppSettings: Codable, Sendable {
    var agentsAtOnce = 4
    // Internal verification-job capacity; retain the legacy storage key for existing installations.
    var heavyStepsAtOnce = 2
    var instructions = ""
    var paused = false
    var usageHoldThreshold = 15
    init() {}
    enum CodingKeys: String, CodingKey { case agentsAtOnce, heavyStepsAtOnce, instructions, paused, usageHoldThreshold }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentsAtOnce = try values.decodeIfPresent(Int.self, forKey: .agentsAtOnce) ?? 4
        heavyStepsAtOnce = try values.decodeIfPresent(Int.self, forKey: .heavyStepsAtOnce) ?? 2
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        usageHoldThreshold = try values.decodeIfPresent(Int.self, forKey: .usageHoldThreshold) ?? 15
    }
}
struct Hooks: Codable, Sendable {
    var afterCreate = ""
    var beforeRun = ""
    var afterRun = ""
    var beforeRemove = ""
    var timeoutSeconds: Double = 60
}
struct CheckDefinition: Codable, Sendable {
    var name: String
    var command: String
    var required = true
}

protocol Record: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable where ID == UUID {}
struct Project: Record {
    static let databaseTableName = "project"
    var id = UUID()
    var name: String
    var repoPath: String
    var host: Host = .github
    var remoteSlug: String
    var defaultBranch = "main"
    var instructions = ""
    var settings = ProjectSettings()
    var paused = false
    var createdAt = Date()
}
struct WorkTask: Record {
    static let databaseTableName = "task"
    var id = UUID()
    var projectId: UUID
    var number: Int
    var title: String
    var description = ""
    var state: TaskState = .todo
    var paused = false
    var rank: Double = 0
    var dependsOn: [UUID] = []
    var stackOn: UUID?
    var askBeforeBuild: Bool?
    var proofRequirement: ProofRequirement = .automatic
    var origin = "sheet"
    var branchName: String?
    var worktreePath: String?
    var workspaceReady = false
    var baseCommitSHA: String?
    var requirementsRevision = 1
    var relatedTaskIds: [UUID] = []
    var deliveryGroupIds: [UUID] = []
    var replacedBy: [UUID] = []
    var pr: PullRequest?
    var retry: Retry?
    var createdAt = Date()
    var updatedAt = Date()
    var doneAt: Date?
}
struct AgentConfiguration: Record {
    static let databaseTableName = "agentConfiguration"
    var id: UUID // Task or project ID; kept separate from mutable lifecycle records.
    var model: String
    var effort: String?
    var recommended = false
    var rationale: String?
}
struct PullRequest: Codable, Sendable { var number: Int; var url: String; var baseBranch: String }
struct Retry: Codable, Sendable { var attempt: Int; var dueAt: Date; var error: String }
struct Session: Record {
    static let databaseTableName = "session"
    var id = UUID()
    var ownerType = "task"
    var ownerId: UUID
    var codexThreadId: String?
    var status = "idle"
    var currentTurn: String?
    var activeModel: String?
    var activeEffort: String?
    var turnCount = 0
    var tokensIn = 0
    var tokensOut = 0
    var startedAt = Date()
    var lastEventAt = Date()
}
struct Message: Record, Equatable {
    static let databaseTableName = "message"
    var id = UUID()
    var sessionId: UUID
    var role: String
    var kind = "text"
    var body: String
    var payload: JSON = .null
    var createdAt = Date()
}
struct Subagent: Record, Equatable {
    static let databaseTableName = "subagent"
    var id = UUID()
    var sessionId: UUID
    var threadId: String
    var parentThreadId: String
    var name = "Subagent"
    var prompt = ""
    var status = "pendingInit"
    var result = ""
    var currentTurn: String?
    var model: String?
    var effort: String?
    var createdAt = Date()
    var updatedAt = Date()

    var isActive: Bool { status == "pendingInit" || status == "running" }
    var statusLabel: String {
        switch status {
        case "pendingInit": "Starting"
        case "running": "Working"
        case "completed": "Done"
        case "interrupted": "Stopped"
        case "errored": "Failed"
        case "shutdown": "Closed"
        case "notFound": "Unavailable"
        default: "Unknown"
        }
    }
}
/// Presentation-only grouping; original messages remain in storage and agent context.
enum ChatReactions {
    static func targets(in messages: [Message], attachmentMessageIDs: Set<UUID> = []) -> [UUID: [Message]] {
        var result: [UUID: [Message]] = [:]
        var preceding: Message?
        for message in messages {
            let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let scalars = text.unicodeScalars
            // Unicode marks ASCII digits as emoji-capable; only their keycap sequences qualify.
            let emoji = text.count == 1 && scalars.first.map {
                $0.properties.isEmoji && ($0.value > 0x7F || scalars.contains { $0.value == 0x20E3 })
            } == true
            if message.role == "agent", message.kind == "text", emoji,
               message.payload["streaming"].bool != true, !attachmentMessageIDs.contains(message.id),
               let preceding, preceding.role == "user", preceding.kind == "text" {
                result[preceding.id, default: []].append(message)
            } else if message.role == "user" || (message.role == "agent" && message.kind != "activity") {
                preceding = message
            }
        }
        return result
    }
}

struct Question: Record {
    static let databaseTableName = "question"
    var id = UUID()
    var taskId: UUID
    var messageId: UUID
    var prompt: String
    var options: [String] = []
    var allowsFreeText = true
    var blocking = true
    var answer: String?
    var answeredBy: String?
    var answeredAt: Date?
    var suggestedAnswer: String?
}
struct Approval: Record {
    static let databaseTableName = "approval"
    var id = UUID()
    var taskId: UUID
    var kind: String
    var status = "pending"
    var planText: String?
    var createdAt = Date()
    var resolvedAt: Date?
}
struct Proof: Record {
    static let databaseTableName = "proof"
    var id = UUID()
    var taskId: UUID
    var recordingPath: String?
    var recordingDuration: Double?
    var recordingRequired = false
    var rationale: String?
    var screenshots: [String] = []
    var checks: [CheckResult] = []
    var files = 0
    var additions = 0
    var deletions = 0
    var summary: String
    var complete = false
    var producedAt = Date()
    var commitSHA: String?
    var requirementsRevision = 1
    var changes: [ChangedFile] = []

    /// Older agents sometimes put a JSON report inside the human-facing summary.
    /// Format it for review without rewriting saved evidence or dropping unknown fields.
    var reviewSummary: String {
        guard let value = try? JSONDecoder().decode(JSON.self, from: Data(summary.utf8)) else { return summary }
        switch value {
        case .object, .array: return Self.formatReviewReport(value)
        default: return summary
        }
    }

    var changeSummary: String { (try? GitHub.changeDescription(summary)) ?? reviewSummary }

    private static func formatReviewReport(_ value: JSON, level: Int = 3) -> String {
        switch value {
        case .object(let fields):
            return fields.keys.sorted().map { key in
                let title = key.replacingOccurrences(of: "_", with: " ")
                let heading = title.prefix(1).uppercased() + title.dropFirst()
                return String(repeating: "#", count: min(level, 6)) + " " + heading + "\n\n"
                    + formatReviewReport(fields[key]!, level: level + 1)
            }.joined(separator: "\n\n")
        case .array(let items):
            return items.map { "- " + formatReviewReport($0, level: level).replacingOccurrences(of: "\n", with: "\n  ") }
                .joined(separator: "\n")
        case .string(let text): return text
        case .null: return "Not provided"
        default: return value.text
        }
    }
}
struct ChangedFile: Codable, Sendable, Identifiable {
    var path: String
    var additions: Int?
    var deletions: Int?
    var id: String { path }
}
struct CheckResult: Codable, Sendable {
    var name: String
    var status: String
    var durationSec: Double
    var logPath: String
}
struct RunAttempt: Record {
    static let databaseTableName = "runAttempt"
    var id = UUID()
    var taskId: UUID
    var attempt: Int
    var phase = "understand"
    var startedAt = Date()
    var endedAt: Date?
    var status = "running"
    var error: String?
}
struct Attachment: Record {
    static let databaseTableName = "attachment"
    var id = UUID()
    var ownerType: String
    var ownerId: UUID
    var kind: String
    var path: String
    var filename: String
    var byteSize: Int
    var durationSec: Double?
    var frames: [String] = []
    var transcript: String?
    var removedAt: Date? = nil
    var sourceAttachmentId: UUID? = nil
}
struct Proposal: Record {
    static let databaseTableName = "proposal"
    struct Item: Codable, Sendable, Equatable {
        var title: String
        var description: String
        var dependsOnIndex: [Int]
        var dependsOnTaskIds: [UUID]?
        var attachmentIds: [UUID]?
        var model: String?
        var effort: String?
        var modelRationale: String?
        var acceptanceCriteria: [String]?
    }
    var id = UUID()
    var projectId: UUID
    var messageId: UUID
    var tasks: [Item]
    var shipAs = "own"
    var status = "open"
    var createdTaskIds: [UUID] = []
}

enum CoreError: Error, LocalizedError, Sendable {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): text } }
}

struct TransitionRules {
    static func validate(from: TaskState, to: TaskState, proofComplete: Bool = false,
                         questionsAnswered: Bool = true, dependenciesReady: Bool = true,
                         planApproved: Bool = true, merged: Bool = false) throws {
        let permitted: Bool
        if to == .canceled { permitted = !from.terminal }
        else {
            switch (from, to) {
            case (.todo, .needsClarification), (.building, .needsClarification),
                 (.needsClarification, .todo), (.humanReview, .building), (.inPR, .building): permitted = true
            case (.todo, .building), (.needsClarification, .building):
                permitted = questionsAnswered && dependenciesReady && planApproved
            case (.building, .humanReview): permitted = proofComplete
            case (.humanReview, .inPR): permitted = proofComplete
            case (.inPR, .done): permitted = merged
            default: permitted = false
            }
        }
        guard permitted else { throw CoreError.invalid("Invalid transition: \(from.rawValue) → \(to.rawValue)") }
    }
}

extension Message {
    // Arbitrary JSON can decode as a plain SQLite string; explicitly decode the stored JSON envelope.
    init(row: Row) throws {
        id = row["id"]; sessionId = row["sessionId"]; role = row["role"]; kind = row["kind"]
        body = row["body"]; createdAt = row["createdAt"]
        let raw: String? = row["payload"]
        payload = try raw.map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) } ?? .null
    }
}
