import Foundation

struct Cooldown {
    static let minimum: TimeInterval = 5
    static let maximum: TimeInterval = 15

    private var lastNotificationDate: Date?
    private var nextAllowedDate: Date?

    mutating func reset() {
        lastNotificationDate = nil
        nextAllowedDate = nil
    }

    mutating func shouldAllow(now: Date = Date(), baseDelay: TimeInterval) -> Bool {
        if let nextAllowedDate, now < nextAllowedDate {
            return false
        }
        return true
    }

    mutating func markNotified(now: Date = Date(), baseDelay: TimeInterval) {
        lastNotificationDate = now
        let clamped = min(max(baseDelay, Self.minimum), Self.maximum)
        let jitter = Double.random(in: 0...clamped)
        nextAllowedDate = now.addingTimeInterval(clamped + jitter)
    }
}

struct NotificationRateLimiter {
    private var timestamps: [Date] = []

    mutating func shouldAllow(maxPerHour: Int, now: Date = Date()) -> Bool {
        guard maxPerHour > 0 else { return true }
        let hourAgo = now.addingTimeInterval(-3600)
        timestamps = timestamps.filter { $0 > hourAgo }
        return timestamps.count < maxPerHour
    }

    mutating func markNotified(now: Date = Date()) {
        timestamps.append(now)
    }
}
