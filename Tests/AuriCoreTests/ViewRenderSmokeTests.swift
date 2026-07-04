import SwiftUI
import XCTest
@testable import AuriCore

/// Construction/render smoke tests for the SwiftUI views that ship in
/// AuriCore. These are not pixel/snapshot tests -- they only assert that the
/// view tree can be built and rendered to a non-degenerate image without
/// crashing, which is enough to catch force-unwraps, infinite layout loops,
/// and other structural regressions in view construction.
@MainActor
final class ViewRenderSmokeTests: XCTestCase {

    // MARK: - Helpers

    private func makeDetection(
        birdName: String = "American Robin",
        scientificName: String = "Turdus migratorius",
        confidence: Double = 0.91,
        timestamp: Date = Date(),
        birdId: Int = 101,
        inferenceMs: Int = 42,
        source: DetectionSource = .live,
        sourceFileName: String? = nil,
        audioOffsetSeconds: Double? = nil,
        rarity: RarityInfo? = nil
    ) -> BirdDetection {
        BirdDetection(
            birdName: birdName,
            scientificName: scientificName,
            confidence: confidence,
            timestamp: timestamp,
            birdId: birdId,
            inferenceMs: inferenceMs,
            source: source,
            sourceFileName: sourceFileName,
            audioOffsetSeconds: audioOffsetSeconds,
            rarity: rarity
        )
    }

    /// Renders `view` off-screen and asserts it produced a non-degenerate
    /// image. Loose on purpose: this is a crash/degenerate-layout guard, not
    /// a pixel-accuracy check.
    private func renderAndAssert(
        _ view: some View,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let renderer = ImageRenderer(content: view.frame(width: 400))
        renderer.proposedSize = .init(width: 400, height: nil)
        let image = renderer.cgImage
        XCTAssertNotNil(image, "expected ImageRenderer to produce an image", file: file, line: line)
        if let image {
            XCTAssertGreaterThan(image.width, 0, "rendered image had zero width", file: file, line: line)
            XCTAssertGreaterThan(image.height, 0, "rendered image had zero height", file: file, line: line)
        }
    }

    // MARK: - DetectionCardView

    func testDetectionCardView_liveRelativeTime_highConfidence() {
        let detection = makeDetection(confidence: 0.91)
        let view = DetectionCardView(
            detection: detection,
            lifetimeCount: 14,
            isIgnored: false,
            timeDisplay: .relative,
            onIgnore: {},
            onDelete: {},
            onSubmit: {}
        )
        renderAndAssert(view)
    }

    func testDetectionCardView_unusualRarity_lowConfidence() {
        let rarity = RarityInfo(level: .unusual, regionLabel: "US-GA", frequencyPercent: 1.2)
        let detection = makeDetection(confidence: 0.42, rarity: rarity)
        let view = DetectionCardView(
            detection: detection,
            isIgnored: false,
            onIgnore: {},
            onDelete: {},
            onSubmit: {}
        )
        renderAndAssert(view)
    }

    func testDetectionCardView_fileSource_absoluteTime() {
        let detection = makeDetection(
            source: .file,
            sourceFileName: "walk.wav",
            audioOffsetSeconds: 95
        )
        let view = DetectionCardView(
            detection: detection,
            isIgnored: false,
            timeDisplay: .absolute,
            onIgnore: {},
            onDelete: {},
            onSubmit: {}
        )
        renderAndAssert(view)
    }

    func testDetectionCardView_isIgnored() {
        let detection = makeDetection()
        let view = DetectionCardView(
            detection: detection,
            isIgnored: true,
            onIgnore: {},
            onDelete: {},
            onSubmit: {}
        )
        renderAndAssert(view)
    }

    // MARK: - SpectrogramView

    func testSpectrogramView_nilSnapshot_rendersPlaceholderAxes() {
        let view = SpectrogramView(snapshot: nil)
        renderAndAssert(view)
    }

    func testSpectrogramView_realSnapshot_withMarker() {
        let engine = SpectrogramEngine(configuration: .default)

        // ~1 second of a 4 kHz sine at 48 kHz (the model's sample rate), which
        // is comfortably within the .default configuration's 100 Hz-15 kHz
        // display range.
        let sampleRate = 48_000
        let frequencyHz = 4_000.0
        let amplitude = 0.5
        let sampleCount = sampleRate
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            samples[index] = Float(amplitude * sin(2.0 * Double.pi * frequencyHz * t))
        }

        _ = engine.ingest(samples: samples)
        let snapshot = engine.makeSnapshot()

        let marker = SpectrogramView.Marker(id: UUID(), timestamp: Date(), label: "Test Bird")
        let view = SpectrogramView(snapshot: snapshot, markers: [marker])
        renderAndAssert(view)
    }
}
