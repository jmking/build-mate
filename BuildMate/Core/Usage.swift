import Foundation

struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let bucket: String
    let name: String
    let remaining: Int
    let minutes: Int?
    let resetsAt: Date?

    var duration: String {
        guard let minutes, minutes > 0 else { return "Usage window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }
}

struct UsageCredits: Sendable {
    let available: Bool
    let unlimited: Bool
    let balance: Decimal?

    init(_ value: JSON) {
        unlimited = value["unlimited"].bool == true
        balance = value["balance"].string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        available = unlimited || (value["hasCredits"].bool == true && (balance.map { $0 > 0 } ?? true))
    }

    var label: String {
        if unlimited { return "Unlimited credits" }
        if let balance { return "\(balance.formatted(.number.precision(.fractionLength(0...2)))) credits" }
        return available ? "Credits available" : "No credits available"
    }
}

struct UsageSnapshot: Sendable {
    var windows: [UsageWindow] = []
    private var creditsByBucket: [String: UsageCredits] = [:]
    private var spendBlockedBuckets: Set<String> = []
    var updatedAt: Date?
    var error: String?
    var refreshing = false

    var limitingWindow: UsageWindow? {
        let codex = windows.filter { $0.bucket == "codex" }
        return (codex.isEmpty ? windows : codex).min { $0.remaining < $1.remaining }
    }

    var credits: UsageCredits? { creditsByBucket[limitingWindow?.bucket ?? "codex"] }
    var canUseCredits: Bool {
        credits?.available == true && !spendBlockedBuckets.contains(limitingWindow?.bucket ?? "codex")
    }

    mutating func receive(_ payload: JSON, replacing: Bool = true) {
        if replacing { windows = []; creditsByBucket = [:]; spendBlockedBuckets = [] }
        let buckets: [String: JSON]
        if case .object(let values) = payload["rateLimitsByLimitId"], !values.isEmpty {
            buckets = values
            windows = []
            creditsByBucket = [:]; spendBlockedBuckets = []
        } else if payload["rateLimits"] != .null {
            let value = payload["rateLimits"]
            let id = value["limitId"].string ?? "codex"
            buckets = [id: value]
        } else {
            updatedAt = Date(); error = nil
            return
        }
        for (id, value) in buckets.sorted(by: { $0.key < $1.key }) {
            // Notifications can omit credit details; explicit null and full reads clear them.
            if case .object(let fields) = value, let creditValue = fields["credits"] {
                creditsByBucket[id] = creditValue == .null ? nil : UsageCredits(creditValue)
            }
            let limit = value["rateLimitReachedType"].string ?? ""
            if value["spendControlReached"].bool == true || limit.hasPrefix("workspace_") {
                spendBlockedBuckets.insert(id)
            } else if value["spendControlReached"].bool == false {
                spendBlockedBuckets.remove(id)
            }
            for slot in ["primary", "secondary"] {
                guard case .object(let fields) = value, fields[slot] != nil else { continue }
                windows.removeAll { $0.id == id + ":" + slot }
                let window = value[slot]
                guard let used = window["usedPercent"].int else { continue }
                windows.append(UsageWindow(id: id + ":" + slot, bucket: id, name: value["limitName"].string ?? (id == "codex" ? "Codex" : id),
                                           remaining: min(100, max(0, 100 - used)), minutes: window["windowDurationMins"].int,
                                           resetsAt: window["resetsAt"].int.map { Date(timeIntervalSince1970: Double($0)) }))
            }
        }
        updatedAt = Date(); error = nil
    }
}
