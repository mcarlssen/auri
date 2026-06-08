import Foundation

/// Per-species notification cooldown. Each species has its own timer.
struct SpeciesCooldown {
    private var nextAllowedBySpecies: [Int: Date] = [:]

    mutating func reset() {
        nextAllowedBySpecies.removeAll()
    }

    mutating func shouldAllow(speciesId: Int, now: Date = Date()) -> Bool {
        guard let nextAllowed = nextAllowedBySpecies[speciesId] else { return true }
        return now >= nextAllowed
    }

    mutating func markNotified(speciesId: Int, cooldownSeconds: TimeInterval, now: Date = Date()) {
        let clamped = max(cooldownSeconds, 0)
        let jitter = clamped > 0 ? Double.random(in: 0...(clamped * 0.1)) : 0
        nextAllowedBySpecies[speciesId] = now.addingTimeInterval(clamped + jitter)
    }
}

/// Per-species cooldown along a virtual timeline (e.g. seconds into an audio file).
struct TimelineSpeciesCooldown {
    private var nextAllowedBySpecies: [Int: TimeInterval] = [:]

    mutating func reset() {
        nextAllowedBySpecies.removeAll()
    }

    mutating func shouldAllow(speciesId: Int, now: TimeInterval) -> Bool {
        guard let nextAllowed = nextAllowedBySpecies[speciesId] else { return true }
        return now >= nextAllowed
    }

    mutating func markQualified(speciesId: Int, cooldownSeconds: TimeInterval, now: TimeInterval) {
        let clamped = max(cooldownSeconds, 0)
        nextAllowedBySpecies[speciesId] = now + clamped
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
