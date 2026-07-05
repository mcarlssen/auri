import Foundation

/// Temporal corroboration for LIVE detections. A lone 3-second window that
/// clears the confidence threshold is a weak signal; with window overlap on,
/// consecutive overlapping windows give several looks at the same audio, so a
/// genuine call clears threshold in more than one of them while a spurious blip
/// usually fires just once. This aggregator holds each species' recent
/// threshold-clearing windows within a one-window horizon and only qualifies a
/// species once enough of them agree, reporting the strongest (max) confidence
/// among the corroborating windows.
///
/// It self-adapts to overlap through the caller-supplied `required` count: with
/// overlap off there is a single look per window, so `required` is 1, every
/// window passes through, and nothing is suppressed.
struct DetectionCorroborator {
    /// One threshold-clearing window observation for a species.
    private struct Observation {
        let timestamp: Date
        let confidence: Double
    }

    /// Recent threshold-clearing windows, keyed by species id.
    private var observations: [Int: [Observation]] = [:]

    /// How far back corroborating windows may reach — one BirdNET window length.
    /// Windows older than this are pruned so only looks at overlapping audio combine.
    let horizonSeconds: TimeInterval

    init(horizonSeconds: TimeInterval) {
        self.horizonSeconds = horizonSeconds
    }

    mutating func reset() {
        observations.removeAll()
    }

    /// Record a threshold-clearing window for `speciesId` and return the
    /// aggregated confidence (max over the windows still within the horizon) once
    /// at least `required` of them agree; returns nil while the species is not yet
    /// corroborated. Only call this for windows that already cleared threshold —
    /// sub-threshold windows must not be recorded here.
    mutating func corroborate(
        speciesId: Int,
        confidence: Double,
        required: Int,
        now: Date = Date()
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-horizonSeconds)
        var recent = (observations[speciesId] ?? []).filter { $0.timestamp >= cutoff }
        recent.append(Observation(timestamp: now, confidence: confidence))
        observations[speciesId] = recent

        guard recent.count >= max(1, required) else { return nil }
        return recent.map(\.confidence).max()
    }
}
