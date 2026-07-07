import Foundation

/// A one-day rollup of live yard activity, shaped for the morning digest.
struct DigestSummary: Equatable {
    /// Start of the summarized day (the day's midnight in the given calendar).
    let day: Date
    let speciesCount: Int
    let detectionCount: Int
    /// Species logged for the first time ever on this day, in the order they were
    /// first heard.
    let newSpeciesNames: [String]
    /// The busiest two-hour window, e.g. "6–8 AM". Nil when the day has fewer than
    /// two detections, where a single blip isn't a meaningful "busiest" window.
    let busiestHourLabel: String?
}

/// Builds the daily digest summary from detection history. Pure and
/// calendar-injectable so behavior is deterministic and testable regardless of
/// the machine's locale or time zone.
enum DailyDigestBuilder {
    /// Summarize a single day of live detections. Returns nil when the day has no
    /// live detections at all — a quiet day is not worth a notification.
    ///
    /// Only `source == .live` entries count: file analysis is not "your yard".
    /// A species is "new" when its earliest live detection across ALL of history
    /// falls within the target day, i.e. there is no earlier live entry for that
    /// species before the day's start.
    static func summarize(
        entries: [BirdDetection],
        day: Date,
        calendar: Calendar = .current
    ) -> DigestSummary? {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        let liveEntries = entries.filter { $0.source == .live }
        let dayEntries = liveEntries.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        guard !dayEntries.isEmpty else { return nil }

        let speciesCount = Set(dayEntries.map(\.birdId)).count
        let detectionCount = dayEntries.count

        // Earliest live detection per species across all history; drives newness.
        var earliestLiveByBird: [Int: Date] = [:]
        for entry in liveEntries {
            if let existing = earliestLiveByBird[entry.birdId] {
                if entry.timestamp < existing { earliestLiveByBird[entry.birdId] = entry.timestamp }
            } else {
                earliestLiveByBird[entry.birdId] = entry.timestamp
            }
        }

        // A species is new when its first-ever live detection lands in the day.
        // Walking the day's detections in time order and emitting each new species
        // once yields the names in the sequence they were first heard.
        var emittedNewIds = Set<Int>()
        let newSpeciesNames = dayEntries
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { entry -> String? in
                guard let earliest = earliestLiveByBird[entry.birdId],
                      earliest >= dayStart, earliest < dayEnd else { return nil }
                guard emittedNewIds.insert(entry.birdId).inserted else { return nil }
                return entry.birdName
            }

        return DigestSummary(
            day: dayStart,
            speciesCount: speciesCount,
            detectionCount: detectionCount,
            newSpeciesNames: newSpeciesNames,
            busiestHourLabel: busiestHourLabel(for: dayEntries, calendar: calendar)
        )
    }

    /// Label the busiest two-hour bin. Bins are aligned to even hours (bin i
    /// covers [2i, 2i+2)); the AM/PM suffix follows the bin's start hour, matching
    /// the aligned examples "12–2 AM" (hours 0–1) and "12–2 PM" (hours 12–13).
    /// Ties resolve to the earlier bin. Nil below two detections.
    private static func busiestHourLabel(
        for dayEntries: [BirdDetection],
        calendar: Calendar
    ) -> String? {
        guard dayEntries.count >= 2 else { return nil }

        var binCounts = [Int](repeating: 0, count: 12)
        for entry in dayEntries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            binCounts[hour / 2] += 1
        }

        guard let maxCount = binCounts.max(), maxCount > 0,
              let binIndex = binCounts.firstIndex(of: maxCount) else {
            return nil
        }

        let startHour = binIndex * 2
        let period = startHour < 12 ? "AM" : "PM"
        return "\(twelveHour(startHour))–\(twelveHour(startHour + 2)) \(period)"
    }

    /// Convert a 24-hour hour into its 12-hour numeric form (0 and 24 → 12).
    private static func twelveHour(_ hour: Int) -> Int {
        let normalized = hour % 12
        return normalized == 0 ? 12 : normalized
    }
}
