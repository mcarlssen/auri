import AVFoundation
import Foundation

/// Retains the short PCM window that triggered each live detection so the user
/// can replay it to validate what they heard, and plays clips back on demand.
///
/// Clips are kept in memory only (session-scoped, capped) — they exist to
/// confirm a live identification, not as a persistent recording archive.
@MainActor
final class DetectionAudioStore: ObservableObject {
    /// The clip currently playing, so cards can show play/stop state.
    @Published private(set) var playingClipID: UUID?

    private struct Clip {
        let samples: [Float]
        let sampleRate: Double
    }

    private var clips: [UUID: Clip] = [:]
    /// Insertion order, for FIFO eviction past `maxClips`.
    private var order: [UUID] = []
    private let maxClips = 40

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineStarted = false
    private var connectedSampleRate: Double?

    init() {
        engine.attach(player)
    }

    /// Store the raw Float32 mono `data` window for a detection.
    func store(id: UUID, data: Data, sampleRate: Int) {
        guard sampleRate > 0, !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return }
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        clips[id] = Clip(samples: samples, sampleRate: Double(sampleRate))
        order.append(id)
        while order.count > maxClips {
            let evicted = order.removeFirst()
            clips.removeValue(forKey: evicted)
        }
    }

    func hasClip(for id: UUID) -> Bool { clips[id] != nil }

    func remove(_ ids: Set<UUID>) {
        for id in ids { clips.removeValue(forKey: id) }
        order.removeAll { ids.contains($0) }
        if let playing = playingClipID, ids.contains(playing) { stop() }
    }

    func removeAll() {
        clips.removeAll()
        order.removeAll()
        stop()
    }

    /// Play the clip if idle, or stop it if it is the one already playing.
    func toggle(id: UUID) {
        if playingClipID == id {
            stop()
        } else {
            play(id: id)
        }
    }

    private func play(id: UUID) {
        guard let clip = clips[id],
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: clip.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(clip.samples.count)
              )
        else { return }

        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { src in
            if let dst = buffer.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: clip.samples.count)
            }
        }

        if connectedSampleRate != clip.sampleRate {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedSampleRate = clip.sampleRate
        }

        do {
            if !engineStarted {
                try engine.start()
                engineStarted = true
            }
        } catch {
            return
        }

        player.stop()
        playingClipID = id
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            Task { @MainActor in
                guard let self, self.playingClipID == id else { return }
                self.playingClipID = nil
            }
        }
        player.play()
    }

    func stop() {
        if engineStarted { player.stop() }
        playingClipID = nil
    }
}
