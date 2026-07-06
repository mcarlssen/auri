import AVFoundation
import Foundation

/// Metadata for the best clip retained per species. The audio itself lives in a
/// sibling `<birdId>.wav` file; this record is what the index persists.
struct BestRecording: Codable, Equatable, Identifiable {
    let birdId: Int
    let detectionId: UUID
    let birdName: String
    let scientificName: String
    let confidence: Double
    let recordedAt: Date
    let fileName: String        // "<birdId>.wav" within the store directory
    let durationSeconds: Double
    var id: Int { birdId }
}

/// Auto-curates a persistent library of the single highest-confidence clip per
/// species — "the sound of my yard". Unlike `DetectionAudioStore` (in-memory,
/// session-scoped, for confirming a live hit), these clips survive quit so the
/// user accumulates keepers they can replay and export from the Heard tab.
///
/// Only one clip is kept per species and no total cap is enforced: a 3-second
/// 16-bit mono clip is ~0.3 MB, and a realistic yard tops out well under 200
/// species, so the whole library stays under ~60 MB.
@MainActor
final class BestRecordingsStore: ObservableObject {
    /// Best clip per species, keyed by birdId.
    @Published private(set) var recordings: [Int: BestRecording] = [:]
    /// The species whose clip is currently playing, so the UI can show state.
    @Published private(set) var playingBirdId: Int?

    private let directory: URL
    private let indexURL: URL

    /// Species whose WAV write is in flight. A burst of detections for one bird
    /// can call `consider` repeatedly before the first write lands; this keeps
    /// concurrent writes from racing on the same file.
    private var writesInFlight: Set<Int> = []

    /// Bumped by `removeAll()`. A write kicked off before a clear must not
    /// resurrect a deleted entry when it finishes, so completions compare the
    /// generation they started under against the current one.
    private var generation = 0

    private var player: AVAudioPlayer?
    private var playerDelegate: BestRecordingPlayerDelegate?

    /// The folder holding the WAV clips and index, exposed for "Show in Finder".
    var directoryURL: URL { directory }

    init(directory: URL? = nil) {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedDirectory = support
                .appendingPathComponent("Auri", isDirectory: true)
                .appendingPathComponent("BestRecordings", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        // `self.` is required here: the `directory` parameter shadows the stored
        // property, and a bare assignment targets the immutable parameter.
        self.directory = resolvedDirectory
        self.indexURL = resolvedDirectory.appendingPathComponent("index.json")
        load()
    }

    /// Whether a candidate at `candidateConfidence` should replace `existing`.
    /// Pure and static so the replacement policy is unit-testable in isolation:
    /// the first clip for a species always stores; later clips must be strictly
    /// more confident to win.
    nonisolated static func shouldReplace(existing: BestRecording?, candidateConfidence: Double) -> Bool {
        guard let existing else { return true }
        return candidateConfidence > existing.confidence
    }

    /// Consider a live detection's audio window as this species' best clip. The
    /// cheap policy check runs here on the main actor; the WAV write happens
    /// off-main so a burst of detections never blocks the UI.
    func consider(detection: BirdDetection, windowData: Data, sampleRate: Int) {
        _ = beginConsider(detection: detection, windowData: windowData, sampleRate: sampleRate)
    }

    /// Test seam: like `consider` but awaits the off-main WAV write so tests can
    /// observe the result without sleeping. Internal on purpose — production
    /// code calls `consider`.
    func considerAndWait(detection: BirdDetection, windowData: Data, sampleRate: Int) async {
        guard let task = beginConsider(detection: detection, windowData: windowData, sampleRate: sampleRate) else {
            return
        }
        await task.value
    }

    func recording(forBirdId birdId: Int) -> BestRecording? {
        recordings[birdId]
    }

    func fileURL(for recording: BestRecording) -> URL {
        directory.appendingPathComponent(recording.fileName)
    }

    /// Play the species' clip if idle, or stop it if it is the one already playing.
    func togglePlayback(birdId: Int) {
        if playingBirdId == birdId {
            stop()
        } else {
            play(birdId: birdId)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playerDelegate = nil
        playingBirdId = nil
    }

    /// Erase the whole library: stop playback, delete every clip and the index,
    /// and clear in-memory state. "Clear my data" means all of it.
    func removeAll() {
        stop()
        // Invalidate any in-flight write so it can't re-add an entry afterward.
        generation &+= 1
        writesInFlight.removeAll()
        recordings.removeAll()
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Consideration

    /// Runs the policy check and, when the candidate wins, kicks off the detached
    /// write. Returns that task (nil when rejected) only so the test seam can
    /// await it; `consider` discards it.
    private func beginConsider(detection: BirdDetection, windowData: Data, sampleRate: Int) -> Task<Void, Never>? {
        let birdId = detection.birdId
        guard Self.shouldReplace(existing: recordings[birdId], candidateConfidence: detection.confidence) else {
            return nil
        }
        guard !writesInFlight.contains(birdId) else { return nil }
        guard sampleRate > 0, !windowData.isEmpty, windowData.count % MemoryLayout<Float>.size == 0 else {
            return nil
        }

        writesInFlight.insert(birdId)

        let fileName = "\(birdId).wav"
        let finalURL = directory.appendingPathComponent(fileName)
        // Keep a .wav extension on the temp file: AVAudioFile infers the WAVE
        // container from the path extension. The UUID keeps it distinct from the
        // final clip and from any other species' write.
        let tempURL = directory.appendingPathComponent("tmp-\(birdId)-\(UUID().uuidString).wav")
        let writeGeneration = generation

        // The clip's duration is fully determined by the packed sample count, so
        // the whole metadata record can be built here on the main actor
        // (BirdDetection isn't Sendable; BestRecording is). The detached task
        // then only does file I/O and hands the finished record back.
        let frameCount = windowData.count / MemoryLayout<Float>.size
        let recording = BestRecording(
            birdId: birdId,
            detectionId: detection.id,
            birdName: detection.birdName,
            scientificName: detection.scientificName,
            confidence: detection.confidence,
            recordedAt: detection.timestamp,
            fileName: fileName,
            durationSeconds: Double(frameCount) / Double(sampleRate)
        )

        return Task.detached(priority: .utility) { [weak self] in
            // Write to a temp file, then move it into place, so a failed or
            // interrupted write can't corrupt the species' existing best clip.
            let wrote = Self.writeWAV(data: windowData, sampleRate: sampleRate, to: tempURL)
            let moved = wrote && Self.moveIntoPlace(from: tempURL, to: finalURL)
            if !moved {
                try? FileManager.default.removeItem(at: tempURL)
            }
            // Rebind the weak capture once, at this closure's own scope, then hop
            // back with a plain cross-actor call. Nesting the rebind inside
            // another concurrent closure (e.g. MainActor.run) references a
            // captured var from concurrently-executing code, which Swift 6
            // rejects.
            guard let self else { return }
            await self.finishWrite(recording, succeeded: moved, writeGeneration: writeGeneration)
        }
    }

    /// Commit (or discard) a finished clip write, back on the main actor: release
    /// the in-flight guard, then publish the metadata and save the index — but
    /// only when the write landed and the library wasn't cleared while it ran.
    private func finishWrite(_ recording: BestRecording, succeeded: Bool, writeGeneration: Int) {
        writesInFlight.remove(recording.birdId)
        guard succeeded else {
            RecognitionLogger.log(
                "best recording write failed for \(recording.birdName)",
                category: "BestRecordings"
            )
            return
        }
        guard generation == writeGeneration else {
            // Library was cleared mid-write; drop the now-orphaned clip.
            try? FileManager.default.removeItem(at: fileURL(for: recording))
            return
        }
        recordings[recording.birdId] = recording
        saveIndex()
        RecognitionLogger.log(
            "stored best recording for \(recording.birdName) " +
            "conf=\(String(format: "%.3f", recording.confidence))",
            category: "BestRecordings"
        )
    }

    // MARK: - Playback

    private func play(birdId: Int) {
        guard let recording = recordings[birdId] else { return }
        let url = fileURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            // The handler is @MainActor-typed, so this closure runs on the main
            // actor and may touch store state directly; the delegate owns the
            // hop from AVAudioPlayer's callback thread.
            let delegate = BestRecordingPlayerDelegate { [weak self] in
                guard let self, self.playingBirdId == birdId else { return }
                self.stop()
            }
            player.delegate = delegate
            self.player = player
            playerDelegate = delegate
            playingBirdId = birdId
            player.play()
        } catch {
            RecognitionLogger.log(
                "best recording playback failed: \(error.localizedDescription)",
                category: "BestRecordings"
            )
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([BestRecording].self, from: data) else { return }
        recordings = Dictionary(decoded.map { ($0.birdId, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let list = recordings.values.sorted { $0.birdId < $1.birdId }
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Files

    /// Write the packed Float32 mono `data` as a 16-bit PCM WAV at `url`, letting
    /// `AVAudioFile` down-convert float→int16 on write. Returns whether the write
    /// succeeded. Pure and `nonisolated` so it can run on the detached write task.
    nonisolated private static func writeWAV(data: Data, sampleRate: Int, to url: URL) -> Bool {
        guard sampleRate > 0, !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return false }
        let frameCount = data.count / MemoryLayout<Float>.size
        guard frameCount > 0 else { return false }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return false
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        var samples = [Float](repeating: 0, count: frameCount)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: frameCount)
            }
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        } catch {
            return false
        }

        return true
    }

    /// Replace whatever is at `finalURL` with `tempURL`. `nonisolated` so it runs
    /// on the detached write task; per-species writes are serialized by the
    /// in-flight guard, so remove-then-move is safe here.
    nonisolated private static func moveIntoPlace(from tempURL: URL, to finalURL: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: tempURL, to: finalURL)
            return true
        } catch {
            return false
        }
    }
}

/// Bridges `AVAudioPlayer`'s completion callback — which can arrive off the main
/// thread — back to the main actor so `playingBirdId` clears cleanly. The handler
/// is `@MainActor`-typed (main-actor closures are Sendable) and rebound to an
/// immutable local before the hop, so no mutable capture crosses the concurrency
/// boundary.
private final class BestRecordingPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = onFinish
        Task { @MainActor in
            onFinish()
        }
    }
}
