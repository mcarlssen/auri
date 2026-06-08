import Foundation

/// Tracks top-1 confidence scores over a rolling window to suggest a practical threshold.
struct ConfidenceRollingEstimator {
    private var samples: [(date: Date, confidence: Double)] = []
    let horizonSeconds: TimeInterval

    init(horizonSeconds: TimeInterval = 30) {
        self.horizonSeconds = horizonSeconds
    }

    mutating func record(confidence: Double, now: Date = Date()) {
        guard confidence > 0 else { return }
        samples.append((now, confidence))
        prune(now: now)
    }

    mutating func reset() {
        samples.removeAll()
    }

    var recentSamples: [(date: Date, confidence: Double)] {
        let cutoff = Date().addingTimeInterval(-horizonSeconds)
        return samples.filter { $0.date >= cutoff }
    }

    var rollingAverageTopConfidence: Double? {
        let recent = recentSamples
        guard !recent.isEmpty else { return nil }
        return recent.map(\.confidence).reduce(0, +) / Double(recent.count)
    }

    /// Suggested threshold: ~85% of the 30-second average top score, clamped to a usable range.
    var suggestedThreshold: Double? {
        let recent = recentSamples
        guard recent.count >= 4, let average = rollingAverageTopConfidence else { return nil }
        let suggested = average * 0.85
        return min(0.55, max(0.10, suggested))
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-horizonSeconds)
        samples.removeAll { $0.date < cutoff }
    }
}
