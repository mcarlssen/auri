import AppKit
import Foundation

enum EBirdSubmission {
    static func makeSummary(
        birdName: String,
        observedDate: Date,
        location: String,
        method: String,
        notes: String
    ) -> String {
        """
        Species: \(birdName)
        Date: \(observedDate.formatted())
        Location: \(location.isEmpty ? "Unknown" : location)
        Method: \(method)
        Notes: \(notes)
        """
    }

    static func submit(
        birdName: String,
        observedDate: Date,
        location: String,
        method: String,
        notes: String,
        openBrowser: Bool = true
    ) {
        let summary = makeSummary(
            birdName: birdName,
            observedDate: observedDate,
            location: location,
            method: method,
            notes: notes
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        if openBrowser, let url = URL(string: "https://ebird.org/submit") {
            NSWorkspace.shared.open(url)
        }
    }

    static func submitBatch(
        detections: [BirdDetection],
        observedDate: Date,
        location: String,
        method: String,
        notesPrefix: String
    ) {
        guard !detections.isEmpty else { return }

        let summaries = detections.map { detection in
            makeSummary(
                birdName: detection.birdName,
                observedDate: detection.timestamp,
                location: location,
                method: method,
                notes: notesPrefix.isEmpty
                    ? "Detected by Auri at \(Int(detection.confidence * 100))% confidence."
                    : notesPrefix
            )
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaries, forType: .string)
        if let url = URL(string: "https://ebird.org/submit") {
            NSWorkspace.shared.open(url)
        }
    }
}
