import Foundation

extension AgentUsageUpdate {
    static func codex(_ payload: JSON, replacing: Bool = true) -> Self {
        var update = Self(replacing: replacing, primaryBucket: "codex")
        let buckets: [String: JSON]
        if case .object(let values) = payload["rateLimitsByLimitId"], !values.isEmpty {
            buckets = values; update.replacing = true
        } else if payload["rateLimits"] != .null {
            let value = payload["rateLimits"]
            buckets = [value["limitId"].string ?? "codex": value]
        } else { return update }
        for (id, value) in buckets.sorted(by: { $0.key < $1.key }) {
            if case .object(let fields) = value, let creditValue = fields["credits"] {
                if creditValue == .null { update.clearedCredits.insert(id) }
                else {
                    let unlimited = creditValue["unlimited"].bool == true
                    let balance = creditValue["balance"].string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
                    update.credits[id] = UsageCredits(available: unlimited || (creditValue["hasCredits"].bool == true && (balance.map { $0 > 0 } ?? true)), unlimited: unlimited, balance: balance)
                }
            }
            let limit = value["rateLimitReachedType"].string ?? ""
            if value["spendControlReached"].bool == true || limit.hasPrefix("workspace_") { update.spendBlocked[id] = true }
            else if value["spendControlReached"].bool == false { update.spendBlocked[id] = false }
            for slot in ["primary", "secondary"] {
                guard case .object(let fields) = value, fields[slot] != nil else { continue }
                update.windowIDs.insert(id + ":" + slot)
                let window = value[slot]
                guard let used = window["usedPercent"].int else { continue }
                update.windows.append(UsageWindow(id: id + ":" + slot, bucket: id, name: value["limitName"].string ?? (id == "codex" ? "Codex" : id),
                    remaining: min(100, max(0, 100 - used)), minutes: window["windowDurationMins"].int,
                    resetsAt: window["resetsAt"].int.map { Date(timeIntervalSince1970: Double($0)) }))
            }
        }
        return update
    }
}
