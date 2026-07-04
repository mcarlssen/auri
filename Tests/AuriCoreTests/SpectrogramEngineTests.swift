import CoreGraphics
import Foundation
import XCTest
@testable import AuriCore

/// Exercises SpectrogramEngine's column arithmetic, ring-buffer capping,
/// backlog discarding, and the frequency→pixel-row placement of a pure tone.
///
/// Expected values are re-derived from the source (see per-test comments) rather
/// than copied, so the tests fail loudly if the ingest/hop or rendering semantics
/// change.
final class SpectrogramEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Memberwise-init parameter order verified against SpectrogramConfiguration:
    /// (sampleRate, fftSize, hopSize, historySeconds, minFrequency, maxFrequency, frequencyScale).
    private func makeConfig(hopSize: Int) -> SpectrogramConfiguration {
        SpectrogramConfiguration(
            sampleRate: 48_000,
            fftSize: 1024,
            hopSize: hopSize,
            historySeconds: 5,
            minFrequency: 100,
            maxFrequency: 15_000,
            frequencyScale: .mel
        )
    }

    private func makeEngine(hopSize: Int) -> SpectrogramEngine {
        SpectrogramEngine(configuration: makeConfig(hopSize: hopSize))
    }

    private func sine(frequency: Float, count: Int, sampleRate: Float, amplitude: Float = 1) -> [Float] {
        (0..<count).map { index in
            amplitude * sinf(2 * Float.pi * frequency * Float(index) / sampleRate)
        }
    }

    // Static display constants pinned from SpectrogramEngine.
    private let displayWidth = 512
    private let displayHeight = 192

    // MARK: - Column arithmetic

    func testIngestReturnsExpectedColumnCount() {
        let hop = 512
        let fftSize = 1024
        // ingest loop: `while availableRawSamples >= sampleCount { consume hop }`.
        // For n samples with n >= fftSize the loop runs floor((n - fftSize)/hop) + 1
        // times. Here n = fftSize + 3*hop = 1024 + 1536 = 2560, so:
        // floor((2560 - 1024)/512) + 1 = floor(1536/512) + 1 = 3 + 1 = 4.
        let n = fftSize + 3 * hop
        let expected = (n - fftSize) / hop + 1
        XCTAssertEqual(expected, 4, "sanity: derived formula must equal 4 for this input")

        let engine = makeEngine(hopSize: hop)
        let produced = engine.ingest(samples: sine(frequency: 1_000, count: n, sampleRate: 48_000))
        XCTAssertEqual(produced, expected)
        XCTAssertEqual(engine.filledColumnCount, expected)
    }

    func testColumnGenerationIsCumulativeAcrossIngestCalls() {
        let engine = makeEngine(hopSize: 512)
        let first = engine.ingest(samples: sine(frequency: 1_000, count: 4_096, sampleRate: 48_000))
        let second = engine.ingest(samples: sine(frequency: 1_000, count: 4_096, sampleRate: 48_000))
        // columnGeneration is the monotonic totalColumnsWritten counter; it equals
        // the sum of columns written across all ingest calls, regardless of capping.
        XCTAssertEqual(engine.columnGeneration, UInt64(first + second))
    }

    func testIngestEmptyReturnsZeroColumns() {
        let engine = makeEngine(hopSize: 512)
        XCTAssertEqual(engine.ingest(samples: []), 0)
        XCTAssertEqual(engine.filledColumnCount, 0)
        XCTAssertEqual(engine.columnGeneration, 0)
    }

    func testFilledColumnCountCapsAtDisplayWidth() {
        // Use a large hop (2048) so a modest sample count still yields many columns.
        // filledColumnsCount caps at displayWidth (512) via min(columnsFilled+1, 512),
        // while columnGeneration keeps counting past the cap.
        let engine = makeEngine(hopSize: 2_048)

        // Feed in chunks so each ingest call's backlog stays well below
        // maxRawBacklogSamples (= 2048*512 + 1024 = 1_049_600) and never triggers
        // the discard path. 4 chunks of 300_000 samples => ~586 columns total.
        let chunk = sine(frequency: 1_000, count: 300_000, sampleRate: 48_000)
        for _ in 0..<4 {
            _ = engine.ingest(samples: chunk)
        }

        XCTAssertEqual(engine.filledColumnCount, displayWidth)
        XCTAssertGreaterThan(engine.columnGeneration, UInt64(displayWidth))
    }

    // MARK: - Reset

    func testResetBufferClearsCounters() {
        let engine = makeEngine(hopSize: 512)
        _ = engine.ingest(samples: sine(frequency: 1_000, count: 8_192, sampleRate: 48_000))
        XCTAssertGreaterThan(engine.filledColumnCount, 0)
        XCTAssertGreaterThan(engine.columnGeneration, 0)

        engine.resetBuffer()
        XCTAssertEqual(engine.filledColumnCount, 0)
        XCTAssertEqual(engine.columnGeneration, 0)
    }

    // MARK: - Backlog discarding

    func testDiscardBacklogCapsColumnsForHugeBuffer() {
        let hop = 512
        let fftSize = 1024
        let engine = makeEngine(hopSize: hop)

        // maxRawBacklogSamples = hop*displayWidth + fftSize = 512*512 + 1024 = 263_168.
        // Ingesting one buffer of (maxRawBacklogSamples + 100_000) samples triggers
        // discardBacklogIfBehind at the top of ingest, dropping the oldest
        // (unread - maxRawBacklogSamples) samples so exactly maxRawBacklogSamples
        // remain unread. The frame loop then produces:
        //   floor((263_168 - 1024)/512) + 1 = floor(262_144/512) + 1 = 512 + 1 = 513.
        let maxBacklog = hop * displayWidth + fftSize
        let n = maxBacklog + 100_000
        let expected = (maxBacklog - fftSize) / hop + 1
        XCTAssertEqual(expected, 513, "sanity: derived backlog-capped column count must be 513")

        let produced = engine.ingest(samples: [Float](repeating: 0, count: n))
        XCTAssertEqual(produced, expected)
        // filledColumnCount is still clamped to displayWidth even though 513 were written.
        XCTAssertEqual(engine.filledColumnCount, displayWidth)
        XCTAssertEqual(engine.columnGeneration, UInt64(expected))
    }

    // MARK: - Snapshot metadata

    func testSnapshotVersionIncreasesAndDimensionsMatch() {
        let engine = makeEngine(hopSize: 512)
        _ = engine.ingest(samples: sine(frequency: 1_000, count: 8_192, sampleRate: 48_000))

        let first = engine.makeSnapshot()
        let second = engine.makeSnapshot()

        // makeSnapshot bumps version (version &+= 1) on every call.
        XCTAssertGreaterThan(second.version, first.version)

        XCTAssertEqual(first.width, displayWidth)
        XCTAssertEqual(first.height, displayHeight)
        XCTAssertEqual(first.cgImage.width, displayWidth)
        XCTAssertEqual(first.cgImage.height, displayHeight)
    }

    // MARK: - Tone placement (verified via rendered snapshot image)

    func testToneLandsInExpectedDisplayRow() {
        let engine = makeEngine(hopSize: 512)

        // Strong 4 kHz tone, enough samples for several columns.
        let tone = sine(frequency: 4_000, count: 4_096, sampleRate: 48_000, amplitude: 0.8)
        let produced = engine.ingest(samples: tone)
        XCTAssertGreaterThanOrEqual(produced, 1)

        let snapshot = engine.makeSnapshot()
        let image = snapshot.cgImage

        // --- Expected display bin (mirrors SpectrogramEngine.displayBinIndex) ---
        // nyquist = sampleRate/2 = 24_000. displayMaxFrequency = min(maxFreq, nyquist*0.98)
        //         = min(15_000, 23_520) = 15_000.
        let nyquist: Float = 24_000
        let displayMaxFrequency = min(Float(15_000), nyquist * 0.98)
        let position = SpectrogramFrequencyScale.mel.displayPosition(
            for: 4_000, minHz: 100, maxHz: displayMaxFrequency
        )
        let clamped = max(0, min(1, position))
        // displayBinIndex = Int(clamped * (height - 1)); for 4 kHz this is 113.
        let expectedBin = Int(clamped * Float(displayHeight - 1))

        // --- Derivation of pixel row from renderPixels ---
        // renderPixels writes: value = sourceColumn[freqIndex] where freqIndex = height-1-row,
        // to memory offset ((height-1-row)*width + displayX)*4. Since the memory row index
        // (height-1-row) equals freqIndex, memory-row R stores sourceColumn[R]; the two
        // "height-1-row" flips cancel. makeImage() wraps the backing buffer without a
        // vertical flip, so CGImage.dataProvider bytes at row R correspond to displayBin R.
        // => expected image row == expectedBin (NOT height-1-expectedBin).
        //
        // The newest column is rendered at x = width-1 (age 0), so we inspect the last column.
        guard let cfData = image.dataProvider?.data else {
            XCTFail("snapshot image has no pixel data")
            return
        }
        let data = cfData as Data
        let bytesPerRow = image.bytesPerRow           // width*4 in practice; read defensively
        let bytesPerPixel = 4
        let lastColumnX = image.width - 1

        var bestRow = 0
        var bestIntensity = -1
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self)
            for row in 0..<image.height {
                let offset = row * bytesPerRow + lastColumnX * bytesPerPixel
                let intensity = Int(base[offset])    // red channel (grayscale RGBA)
                if intensity > bestIntensity {
                    bestIntensity = intensity
                    bestRow = row
                }
            }
        }

        XCTAssertGreaterThan(bestIntensity, 0, "expected non-zero energy in the tone column")
        // ±2 rows tolerance absorbs FFT-bin quantization and window leakage.
        XCTAssertLessThanOrEqual(
            abs(bestRow - expectedBin), 2,
            "4 kHz tone landed at row \(bestRow); expected ~\(expectedBin)"
        )
    }
}
