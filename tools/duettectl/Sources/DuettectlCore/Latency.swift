import DuettectlDSP
import Foundation

public struct LatencyEstimate: Equatable {
    public var lagFrames: Int
    /// 0..1; above about 0.5 can be trusted.
    public var confidence: Double

    public init(lagFrames: Int, confidence: Double) {
        self.lagFrames = lagFrames
        self.confidence = confidence
    }
}

/// The test signal of the loopback check: core's LatencyEstimator::makeChirp.
public enum Chirp {
    public static func make(sampleRate: Double, startHz: Double, endHz: Double, frames: Int,
                            amplitude: Float = 0.5) -> [Float] {
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            duettectl_make_chirp(base, buffer.count, sampleRate, startHz, endHz, amplitude)
        }
        return out
    }
}

/// core's LatencyEstimator::estimate.
public enum Latency {
    public static func estimate(reference: [Float], recording: [Float], maxLagFrames: Int) -> LatencyEstimate {
        let result = reference.withUnsafeBufferPointer { ref in
            recording.withUnsafeBufferPointer { rec -> duettectl_latency in
                guard let r = ref.baseAddress, let s = rec.baseAddress else {
                    return duettectl_latency(lag_frames: 0, confidence: 0)
                }
                return duettectl_estimate_latency(r, ref.count, s, rec.count, max(0, maxLagFrames))
            }
        }
        return LatencyEstimate(lagFrames: Int(result.lag_frames), confidence: result.confidence)
    }
}

/// One I/O cycle of a recorder or player (see duettectl_io.h).
public struct IOBlock: Equatable {
    /// Sample time of the cycle's buffer: input time for a recorder, output time for a player.
    public var sampleTime: Double
    /// "Now" when the HAL called the IOProc.
    public var nowSampleTime: Double
    public var nowHostTime: UInt64
    public var frames: Int
    /// Recorder: recording index of the first frame. Player: stream position, -1 before arming.
    public var position: Int64

    public init(sampleTime: Double, nowSampleTime: Double, nowHostTime: UInt64 = 0, frames: Int, position: Int64) {
        self.sampleTime = sampleTime
        self.nowSampleTime = nowSampleTime
        self.nowHostTime = nowHostTime
        self.frames = frames
        self.position = position
    }
}

/// What the loopback check measured. Times are sample times on the clock "Duette" and
/// "Duette Sink" share.
public struct LoopbackResult: Equatable {
    /// Where the writer put the chirp on the sink.
    public var chirpSinkTime: Double
    /// Where the recording of "Duette" holds it.
    public var chirpDuetteTime: Double?
    /// The recording index of that place.
    public var chirpRecordingIndex: Int64?
    /// chirpDuetteTime - chirpSinkTime. The loopback is indexed by sample time, so 0.
    public var sampleOffset: Double?
    /// Of the cross-correlation that found the chirp.
    public var confidence: Double
    /// Frames from the writer's IOProc call that produced a frame to the reader's call that got
    /// it, largest and mean over the chirp. This is the delay an app recording "Duette" sees.
    public var latencyMax: Double?
    public var latencyMean: Double?
    /// Sink sample time just after the last frame the writer wrote.
    public var writerEnd: Double?
    /// Duette sample time of the last non-zero frame recorded.
    public var lastSound: Double?
    /// lastSound + 1 - writerEnd: how long "Duette" kept playing after the writer's last frame.
    public var silenceDelay: Double?
    /// Non-zero frames recorded one buffer or more after writerEnd.
    public var nonZeroAfterStop: Int
    /// How much recording there is after writerEnd, in frames.
    public var observedAfterStop: Double
}

/// Lines a player's and a recorder's cycle logs up on their shared clock.
public enum LoopbackAnalysis {
    /// - Parameters:
    ///   - chirp: what the player played first after it was armed (then a tone until it stopped).
    ///   - writer: the player's cycles on the sink.
    ///   - reader: the recorder's cycles on "Duette".
    ///   - recording: one channel of the recording; `recording[i]` is recording index
    ///     `recordingStart + i`.
    ///   - searchMargin: how far from the expected place the chirp is looked for.
    public static func analyze(chirp: [Float], writer: [IOBlock], reader: [IOBlock], recording: [Float],
                               recordingStart: Int64 = 0, bufferFrames: Int,
                               searchMargin: Int = 8192) -> LoopbackResult? {
        guard !chirp.isEmpty, !recording.isEmpty else { return nil }
        let readerBlocks = reader.filter { $0.sampleTime >= 0 && $0.frames > 0 }.sorted { $0.position < $1.position }
        let played = writer.filter { $0.position >= 0 && $0.sampleTime >= 0 && $0.frames > 0 }
        guard let first = played.min(by: { $0.position < $1.position }), !readerBlocks.isEmpty else { return nil }
        let chirpSinkTime = first.sampleTime - Double(first.position)

        func duetteTime(ofIndex index: Int64) -> Double? {
            guard let block = blockContaining(index, in: readerBlocks) else { return nil }
            return block.sampleTime + Double(index - block.position)
        }
        func readerBlock(atDuetteTime time: Double) -> IOBlock? {
            readerBlocks.first { time >= $0.sampleTime && time < $0.sampleTime + Double($0.frames) }
        }
        func recordingIndex(ofDuetteTime time: Double) -> Int? {
            guard let block = readerBlock(atDuetteTime: time) else { return nil }
            return Int(block.position - recordingStart) + Int(time - block.sampleTime)
        }

        // 1. Find the chirp in the recording, near where it should be.
        var windowStart = 0
        var windowEnd = recording.count
        if let expected = recordingIndex(ofDuetteTime: chirpSinkTime) {
            windowStart = max(0, expected - searchMargin)
            windowEnd = min(recording.count, expected + chirp.count + searchMargin)
        }
        var result = LoopbackResult(chirpSinkTime: chirpSinkTime, confidence: 0, nonZeroAfterStop: 0, observedAfterStop: 0)
        if windowEnd - windowStart >= chirp.count {
            let window = Array(recording[windowStart..<windowEnd])
            let estimate = Latency.estimate(reference: chirp, recording: window, maxLagFrames: window.count - chirp.count)
            result.confidence = estimate.confidence
            let foundIndex = recordingStart + Int64(windowStart + estimate.lagFrames)
            if estimate.confidence > 0, let found = duetteTime(ofIndex: foundIndex) {
                result.chirpDuetteTime = found
                result.chirpRecordingIndex = foundIndex
                result.sampleOffset = found - chirpSinkTime
            }
        }

        // 2. Callback-to-callback latency of every chirp frame.
        if let offset = result.sampleOffset {
            var worst = -Double.infinity
            var sum = 0.0
            var count = 0
            for block in played where block.position < Int64(chirp.count) {
                for f in 0..<block.frames where block.position + Int64(f) < Int64(chirp.count) {
                    let time = block.sampleTime + Double(f) + offset
                    guard let delivered = readerBlock(atDuetteTime: time) else { continue }
                    let latency = delivered.nowSampleTime - block.nowSampleTime
                    worst = max(worst, latency)
                    sum += latency
                    count += 1
                }
            }
            if count > 0 {
                result.latencyMax = worst
                result.latencyMean = sum / Double(count)
            }
        }

        // 3. Silence after the writer stopped.
        if let last = played.max(by: { $0.position < $1.position }) {
            let writerEnd = last.sampleTime + Double(last.frames)
            result.writerEnd = writerEnd
            var lastSound: Double?
            var nonZeroAfter = 0
            var latest = -Double.infinity
            for (i, sample) in recording.enumerated() {
                guard let time = duetteTime(ofIndex: recordingStart + Int64(i)) else { continue }
                latest = max(latest, time)
                if sample != 0 {
                    lastSound = max(lastSound ?? -Double.infinity, time)
                    if time >= writerEnd + Double(bufferFrames) { nonZeroAfter += 1 }
                }
            }
            result.lastSound = lastSound
            result.nonZeroAfterStop = nonZeroAfter
            result.observedAfterStop = max(0, latest + 1 - writerEnd)
            if let lastSound { result.silenceDelay = lastSound + 1 - writerEnd }
        }
        return result
    }

    static func blockContaining(_ index: Int64, in blocks: [IOBlock]) -> IOBlock? {
        // Blocks are sorted by position; binary search for the last one starting at or before index.
        var low = 0
        var high = blocks.count - 1
        var found: IOBlock?
        while low <= high {
            let mid = (low + high) / 2
            if blocks[mid].position <= index {
                found = blocks[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let block = found, index < block.position + Int64(block.frames) else { return nil }
        return block
    }
}
