import XCTest
@testable import AuriCore

final class AudioMeterStatsTests: XCTestCase {

    func testEmptySamples_returnsZerosAndPassesThroughReceivingFlag() {
        let stats = AudioMeterStats.from(samples: [], buffersReceived: 42, isReceiving: true)
        XCTAssertEqual(stats.rms, 0)
        XCTAssertEqual(stats.peak, 0)
        XCTAssertEqual(stats.rmsDB, -80)
        XCTAssertEqual(stats.peakDB, -80)
        XCTAssertEqual(stats.buffersReceived, 42)
        XCTAssertTrue(stats.isReceivingAudio)
    }

    func testEmptySamples_isReceivingFalsePassesThrough() {
        let stats = AudioMeterStats.from(samples: [], buffersReceived: 0, isReceiving: false)
        XCTAssertFalse(stats.isReceivingAudio)
        XCTAssertEqual(stats.buffersReceived, 0)
        XCTAssertEqual(stats.rmsDB, -80)
        XCTAssertEqual(stats.peakDB, -80)
    }

    func testConstantSignal_rmsPeakAndDB() {
        let samples = [Float](repeating: 0.5, count: 1000)
        let stats = AudioMeterStats.from(samples: samples, buffersReceived: 1, isReceiving: true)
        XCTAssertEqual(stats.rms, 0.5, accuracy: 1e-4)
        XCTAssertEqual(stats.peak, 0.5, accuracy: 1e-4)
        XCTAssertEqual(stats.rmsDB, 20 * log10(Float(0.5)), accuracy: 0.01)
    }

    func testMixedSignSignal_peakAndRmsUseMagnitude() {
        let samples: [Float] = [-1, 1, -1, 1]
        let stats = AudioMeterStats.from(samples: samples, buffersReceived: 1, isReceiving: true)
        XCTAssertEqual(stats.peak, 1, accuracy: 1e-6)
        XCTAssertEqual(stats.rms, 1, accuracy: 1e-6)
    }

    func testTinySignalBelowFloor_dBClampedToMinus80() {
        let samples = [Float](repeating: 1e-9, count: 100)
        let stats = AudioMeterStats.from(samples: samples, buffersReceived: 1, isReceiving: true)
        XCTAssertEqual(stats.rmsDB, -80)
        XCTAssertEqual(stats.peakDB, -80)
    }

    func testFullScaleSignal_zeroDB() {
        let samples = [Float](repeating: 1.0, count: 100)
        let stats = AudioMeterStats.from(samples: samples, buffersReceived: 1, isReceiving: true)
        XCTAssertEqual(stats.rms, 1.0, accuracy: 1e-6)
        XCTAssertEqual(stats.peak, 1.0, accuracy: 1e-6)
        XCTAssertEqual(stats.rmsDB, 0, accuracy: 1e-4)
        XCTAssertEqual(stats.peakDB, 0, accuracy: 1e-4)
    }
}
