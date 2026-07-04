import Accelerate
import Foundation

/// Accumulates mono float32 PCM bytes and yields fixed-size analysis windows
/// advanced by a configurable hop, optionally skipping windows whose peak
/// magnitude falls below a silence gate.
struct WindowAccumulator {
    let windowByteCount: Int
    let windowSampleCount: Int
    var hopByteCount: Int
    var silenceGateEnabled: Bool
    var silenceGateThresholdLinear: Float
    private(set) var silentWindowsSkipped: UInt64
    private var buffer: Data

    init(windowSampleCount: Int, hopByteCount: Int) {
        self.windowSampleCount = windowSampleCount
        self.windowByteCount = windowSampleCount * MemoryLayout<Float>.size
        self.hopByteCount = hopByteCount
        self.silenceGateEnabled = false
        self.silenceGateThresholdLinear = 0
        self.silentWindowsSkipped = 0
        self.buffer = Data()
    }

    mutating func reset(keepingCapacity: Bool) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func resetSilentCount() {
        silentWindowsSkipped = 0
    }

    /// Appends a chunk of PCM bytes, trimming any trailing bytes so the buffer
    /// count stays a multiple of a float's size.
    mutating func append(_ chunk: Data) {
        buffer.append(chunk)
        let floatByteSize = MemoryLayout<Float>.size
        let remainder = buffer.count % floatByteSize
        if remainder != 0 {
            buffer.removeLast(remainder)
        }
    }

    /// Returns the next analysis window, advancing by the hop. Returns nil when
    /// fewer than `windowByteCount` bytes are buffered. When the gate is enabled,
    /// windows whose peak magnitude falls below the threshold are skipped (and
    /// counted) until a non-silent window is found or the buffer runs short.
    mutating func nextWindow() -> Data? {
        while buffer.count >= windowByteCount {
            if silenceGateEnabled, windowPeakBelowGate() {
                silentWindowsSkipped &+= 1
                buffer.removeFirst(hopByteCount)
                continue
            }
            let window = buffer.prefix(windowByteCount)
            let result = Data(window)
            buffer.removeFirst(hopByteCount)
            return result
        }
        return nil
    }

    /// True when the next window's peak magnitude is below the silence gate,
    /// meaning inference would be spent on inaudible audio.
    private func windowPeakBelowGate() -> Bool {
        var peak: Float = 0
        buffer.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            guard let base = floats.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(windowSampleCount))
        }
        return peak < silenceGateThresholdLinear
    }
}
