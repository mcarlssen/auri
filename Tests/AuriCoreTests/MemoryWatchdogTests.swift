import CoreML
import Darwin
import XCTest
@testable import AuriCore

/// Tier-3 informational leak guard for the Core ML prediction path.
///
/// Context: `BirdNetCoreMLRecognizer.recognize(...)` wraps every
/// `model.prediction(from:)` call in `autoreleasepool { }` with this comment
/// in the source:
///
/// > The prediction's IOSurface-backed input/output buffers are autoreleased,
/// > and this actor's cooperative thread never drains its pool on its own, so
/// > every window leaks its buffers until the pool is drained explicitly.
///
/// i.e. the app previously leaked IOSurface-backed Core ML buffers when
/// predictions ran without an explicit autoreleasepool drain. This test
/// exercises the same pattern the app now uses (each prediction wrapped in
/// its own `autoreleasepool`) and checks that resident memory does not grow
/// without bound across repeated predictions. The threshold is intentionally
/// very generous -- this is not a precise leak detector, only a guard
/// against the unbounded-leak class described above.
final class MemoryWatchdogTests: XCTestCase {

    // MARK: - Repo / model location

    /// Walks up from this source file looking for the package manifest,
    /// bounded so a missing manifest can't spin forever.
    private static func repoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                break
            }
            url = parent
        }
        return nil
    }

    private static var modelURL: URL? {
        repoRoot()?.appendingPathComponent("Auri/Resources/BirdNet/audio-model-fp16.mlpackage")
    }

    // MARK: - Model loading (once for the whole test class)

    private struct LoadedModel {
        let model: MLModel
        let inputFeatureName: String
    }

    /// Loaded lazily on first access and cached for the lifetime of the test
    /// process -- compiling the .mlpackage takes real time, and every test in
    /// this file wants the same cpuOnly-configured model.
    private static let loadedModel: LoadedModel? = {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            return nil
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let compiledURL = try MLModel.compileModel(at: modelURL)
            let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
                return nil
            }
            return LoadedModel(model: model, inputFeatureName: inputName)
        } catch {
            return nil
        }
    }()

    // MARK: - Memory helper

    /// Current resident (physical) memory footprint of this process, in
    /// bytes, as reported by the kernel via TASK_VM_INFO. This is the same
    /// metric backing Xcode's memory gauge / Activity Monitor's "Memory"
    /// column.
    private func residentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: - Test

    func testRepeatedPredictionsDoNotAccumulateMemory() throws {
        guard let modelURL = Self.modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("BirdNET Core ML model not present in this checkout; skipping memory watchdog test.")
        }
        guard let loaded = Self.loadedModel else {
            throw XCTSkip("Could not compile/load the BirdNET Core ML model; skipping memory watchdog test.")
        }

        // A fixed chirp, reused for every prediction (warmup and measured
        // alike) so any observed memory growth is attributable to the
        // prediction machinery itself rather than to varying input data.
        let sampleCount = BirdNetCoreMLRecognizer.windowSamples
        var chirp = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let t = Double(index) / Double(BirdNetCoreMLRecognizer.modelSampleRate)
            let sweepHz = 500.0 + 3_000.0 * t
            chirp[index] = Float(0.3 * sin(2.0 * Double.pi * sweepHz * t))
        }

        func predictOnce() throws {
            let provider = try BirdNetCoreMLRecognizer.makeInputProvider(
                samples: chirp,
                featureName: loaded.inputFeatureName
            )
            _ = try loaded.model.prediction(from: provider)
        }

        // Warmup: let Core ML finish any lazy setup (e.g. compute-graph
        // planning) before we take the baseline measurement below.
        for _ in 0..<3 {
            try autoreleasepool {
                try predictOnce()
            }
        }

        let baseline = residentFootprint()
        guard baseline > 0 else {
            throw XCTSkip("task_info(TASK_VM_INFO) reported 0 bytes; cannot measure resident footprint on this host.")
        }

        // Mirrors BirdNetCoreMLRecognizer.recognize(...): every prediction is
        // wrapped in its own autoreleasepool so the IOSurface-backed
        // input/output buffers Core ML allocates get released promptly
        // instead of accumulating for the lifetime of the (long-lived) actor
        // thread's pool.
        for _ in 0..<25 {
            try autoreleasepool {
                try predictOnce()
            }
        }

        let after = residentFootprint()
        let growthBytes = after > baseline ? after - baseline : 0
        let growthMB = Double(growthBytes) / (1024 * 1024)

        // Very generous threshold (500 MB across 28 total predictions): this
        // only catches the unbounded-leak class this test guards against, not
        // routine allocator/paging noise. A failure here indicates a Core ML
        // prediction-buffer accumulation regression (e.g. a missing or broken
        // autoreleasepool drain around `model.prediction`), not a precise
        // memory budget violation.
        XCTAssertLessThan(
            growthMB,
            500,
            "Resident memory grew by \(growthMB) MB across 25 repeated predictions; " +
            "this may indicate a Core ML prediction buffer leak (missing autoreleasepool drain)."
        )
    }
}
