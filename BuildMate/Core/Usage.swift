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

struct UsageSnapshot: Sendable {
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var error: String?
    var refreshing = false

    var limitingWindow: UsageWindow? {
        let codex = windows.filter { $0.bucket == "codex" }
        return (codex.isEmpty ? windows : codex).min { $0.remaining < $1.remaining }
    }

    mutating func receive(_ payload: JSON, replacing: Bool = true) {
        if replacing { windows = [] }
        let buckets: [String: JSON]
        if case .object(let values) = payload["rateLimitsByLimitId"], !values.isEmpty {
            buckets = values
            windows = []
        } else if payload["rateLimits"] != .null {
            let value = payload["rateLimits"]
            let id = value["limitId"].string ?? "codex"
            buckets = [id: value]
            windows.removeAll { $0.bucket == id }
        } else {
            windows = []; updatedAt = Date(); error = nil
            return
        }
        for (id, value) in buckets.sorted(by: { $0.key < $1.key }) {
            for slot in ["primary", "secondary"] {
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
