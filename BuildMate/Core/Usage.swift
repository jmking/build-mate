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

    var label: String {
        if unlimited { return "Unlimited credits" }
        if let balance { return "\(balance.formatted(.number.precision(.fractionLength(0...2)))) credits" }
        return available ? "Credits available" : "No credits available"
    }
}

struct UsageSnapshot: Sendable {
    var windows: [UsageWindow] = []
    private var primaryBucket: String?
    private var creditsByBucket: [String: UsageCredits] = [:]
    private var spendBlockedBuckets: Set<String> = []
    var updatedAt: Date?
    var error: String?
    var refreshing = false

    var limitingWindow: UsageWindow? {
        let preferred = windows.filter { $0.bucket == primaryBucket }
        return (preferred.isEmpty ? windows : preferred).min { $0.remaining < $1.remaining }
    }

    var credits: UsageCredits? { (limitingWindow?.bucket ?? primaryBucket).flatMap { creditsByBucket[$0] } }
    var canUseCredits: Bool {
        guard let bucket = limitingWindow?.bucket ?? primaryBucket else { return false }
        return credits?.available == true && !spendBlockedBuckets.contains(bucket)
    }

    mutating func apply(_ update: AgentUsageUpdate) {
        if update.replacing { windows = []; creditsByBucket = [:]; spendBlockedBuckets = [] }
        if let bucket = update.primaryBucket { primaryBucket = bucket }
        windows.removeAll { update.windowIDs.contains($0.id) }
        windows += update.windows
        for bucket in update.clearedCredits { creditsByBucket[bucket] = nil }
        creditsByBucket.merge(update.credits) { _, new in new }
        for (bucket, blocked) in update.spendBlocked {
            if blocked { spendBlockedBuckets.insert(bucket) } else { spendBlockedBuckets.remove(bucket) }
        }
        updatedAt = Date(); error = nil
    }
}

/// Incremental account updates preserve omitted fields; a full read replaces the snapshot.
struct AgentUsageUpdate: Sendable {
    var replacing = false
    var primaryBucket: String?
    var windows: [UsageWindow] = []
    var windowIDs: Set<String> = []
    var credits: [String: UsageCredits] = [:]
    var clearedCredits: Set<String> = []
    var spendBlocked: [String: Bool] = [:]
}
