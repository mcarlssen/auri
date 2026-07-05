import Accelerate
import Foundation

/// Accumulates mono float32 PCM bytes and yields fixed-size analysis windows
/// advanced by a configurable hop, optionally skipping windows whose peak
/// magnitude falls below a silence gate.
///
/// Samples are held in a fixed-capacity circular buffer of `Float`: appending
/// copies incoming samples into the ring (growing only when it must), and
/// draining a window copies one window's worth of samples out and advances a
/// read cursor by the hop — never memmoving the buffered remainder.
struct WindowAccumulator {
    let windowByteCount: Int
    let windowSampleCount: Int
    var hopByteCount: Int
    var silenceGateEnabled: Bool
    var silenceGateThresholdLinear: Float
    private(set) var silentWindowsSkipped: UInt64

    /// Circular sample storage. `readIndex` is the offset of the oldest buffered
    /// sample and `sampleCount` the number of valid samples ahead of it; both
    /// wrap around `ring.count`.
    private var ring: [Float]
    private var readIndex: Int
    private var sampleCount: Int

    init(windowSampleCount: Int, hopByteCount: Int) {
        self.windowSampleCount = windowSampleCount
        self.windowByteCount = windowSampleCount * MemoryLayout<Float>.size
        self.hopByteCount = hopByteCount
        self.silenceGateEnabled = false
        self.silenceGateThresholdLinear = 0
        self.silentWindowsSkipped = 0
        self.ring = []
        self.readIndex = 0
        self.sampleCount = 0
    }

    mutating func reset(keepingCapacity: Bool) {
        readIndex = 0
        sampleCount = 0
        if !keepingCapacity {
            ring = []
        }
    }

    mutating func resetSilentCount() {
        silentWindowsSkipped = 0
    }

    /// Appends a chunk of PCM bytes, dropping any trailing bytes that don't form
    /// a whole float so the buffered sample stream stays float-aligned.
    mutating func append(_ chunk: Data) {
        let floatByteSize = MemoryLayout<Float>.size
        let newSamples = chunk.count / floatByteSize
        guard newSamples > 0 else { return }

        ensureCapacity(sampleCount + newSamples)

        let capacity = ring.count
        let writeIndex = (readIndex + sampleCount) % capacity
        let firstRun = min(newSamples, capacity - writeIndex)

        chunk.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            guard let srcBase = floats.baseAddress else { return }
            ring.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                memcpy(dstBase + writeIndex, srcBase, firstRun * floatByteSize)
                if firstRun < newSamples {
                    memcpy(dstBase, srcBase + firstRun, (newSamples - firstRun) * floatByteSize)
                }
            }
        }
        sampleCount += newSamples
    }

    /// Returns the next analysis window, advancing by the hop. Returns nil when
    /// fewer than `windowSampleCount` samples are buffered. When the gate is
    /// enabled, windows whose peak magnitude falls below the threshold are skipped
    /// (and counted) until a non-silent window is found or the buffer runs short.
    mutating func nextWindow() -> Data? {
        let hopSamples = hopByteCount / MemoryLayout<Float>.size
        while sampleCount >= windowSampleCount {
            if silenceGateEnabled, windowPeakBelowGate() {
                silentWindowsSkipped &+= 1
                advance(by: hopSamples)
                continue
            }
            let result = copyWindow()
            advance(by: hopSamples)
            return result
        }
        return nil
    }

    /// True when the next window's peak magnitude is below the silence gate,
    /// meaning inference would be spent on inaudible audio. Gating on peak (rather
    /// than window RMS) keeps a window alive as long as any sample rises above the
    /// threshold, so a brief call in otherwise-quiet air is still analyzed — an RMS
    /// measure averages that call away across the 3-second window and skips it.
    private func windowPeakBelowGate() -> Bool {
        var peak: Float = 0
        let contiguous = min(windowSampleCount, ring.count - readIndex)
        if contiguous == windowSampleCount {
            // Window doesn't wrap the ring; measure the samples in place.
            ring.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                vDSP_maxmgv(base + readIndex, 1, &peak, vDSP_Length(windowSampleCount))
            }
        } else {
            // Window wraps the ring end; gather it contiguously before measuring.
            var scratch = [Float](repeating: 0, count: windowSampleCount)
            copyOut(into: &scratch, count: windowSampleCount)
            scratch.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_maxmgv(base, 1, &peak, vDSP_Length(windowSampleCount))
            }
        }
        return peak < silenceGateThresholdLinear
    }

    /// Copies one window's worth of samples out of the ring into a fresh, tightly
    /// packed `Data`, unwrapping across the ring's end boundary.
    private func copyWindow() -> Data {
        var out = [Float](repeating: 0, count: windowSampleCount)
        copyOut(into: &out, count: windowSampleCount)
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Copies `count` samples starting at the read cursor into `destination`,
    /// unwrapping the ring across its end boundary.
    private func copyOut(into destination: inout [Float], count: Int) {
        guard count > 0 else { return }
        let firstRun = min(count, ring.count - readIndex)
        ring.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            destination.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                memcpy(dstBase, srcBase + readIndex, firstRun * MemoryLayout<Float>.size)
                if firstRun < count {
                    memcpy(dstBase + firstRun, srcBase, (count - firstRun) * MemoryLayout<Float>.size)
                }
            }
        }
    }

    /// Advances the read cursor past `samples` samples, dropping them from the
    /// buffer without moving the remaining data.
    private mutating func advance(by samples: Int) {
        let step = min(samples, sampleCount)
        readIndex = (readIndex + step) % max(ring.count, 1)
        sampleCount -= step
    }

    /// Ensures the ring can hold at least `minimum` samples, reallocating and
    /// unwrapping existing data to start at index 0 when it must grow. Growth is
    /// geometric so a steady append/drain cycle stops reallocating once the ring
    /// is large enough.
    private mutating func ensureCapacity(_ minimum: Int) {
        guard minimum > ring.count else { return }
        let newCapacity = max(minimum, ring.count * 2)
        var grown = [Float](repeating: 0, count: newCapacity)
        copyOut(into: &grown, count: sampleCount)
        ring = grown
        readIndex = 0
    }
}
