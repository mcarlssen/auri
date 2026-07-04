import XCTest
@testable import AuriCore

final class SanityTests: XCTestCase {
    func testWindowSamples() {
        XCTAssertEqual(BirdNetCoreMLRecognizer.windowSamples, 144_000)
    }

    func testModelSampleRate() {
        XCTAssertEqual(BirdNetCoreMLRecognizer.modelSampleRate, 48_000)
    }
}
