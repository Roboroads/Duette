import CoreAudio
import DuetteEngine
import Foundation

// Swift faces of the probe IOProcs in duette_probe.h, and the measurement "Measure latency" runs
// with them: a chirp played into "Duette Sink" and recorded from "Duette".

private func deviceName(_ device: AudioObjectID) -> String {
    (try? AudioObject(device).getString(kAudioObjectPropertyName)) ?? "device \(device)"
}

/// Records two input channels of a device (see duette_probe.h).
public final class ProbeRecorder {
    public let device: AudioObjectID
    public let sampleRate: Double
    private let handle: OpaquePointer
    private let blockCapacity: Int
    private var procID: AudioDeviceIOProcID?

    /// Keeps the latest `seconds` of audio.
    public init(device: AudioObjectID, seconds: Double, sampleRate: Double = 48000, firstChannel: UInt32 = 0) throws {
        let frames = max(4096, Int(seconds * sampleRate))
        let blocks = max(1024, frames / 16)
        guard let handle = duette_probe_recorder_create(frames, blocks, firstChannel) else {
            throw CoreAudioError(OSStatus(kAudioHardwareUnspecifiedError), "allocate a recorder for \(seconds) s")
        }
        self.device = device
        self.sampleRate = sampleRate
        self.handle = handle
        self.blockCapacity = blocks
    }

    deinit {
        stop()
        duette_probe_recorder_destroy(handle)
    }

    public func start() throws {
        var proc: AudioDeviceIOProcID?
        let status = duette_probe_recorder_start(handle, device, &proc)
        guard status == kNoError, let proc else { throw CoreAudioError(status, "start recording from \(deviceName(device))") }
        procID = proc
    }

    public func stop() {
        guard let procID else { return }
        _ = duette_probe_stop(device, procID)
        self.procID = nil
    }

    public var isRunning: Bool { procID != nil }
    public var frames: UInt64 { duette_probe_recorder_frames(handle) }
    public var cycles: UInt64 { duette_probe_recorder_cycles(handle) }
    public var inputChannels: UInt32 { duette_probe_recorder_input_channels(handle) }
    public var capacity: Int { duette_probe_recorder_capacity(handle) }

    /// Polls until `count` frames are recorded or `timeout` seconds pass.
    @discardableResult
    public func waitForFrames(_ count: UInt64, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while frames < count {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Interleaved stereo frames from recording index `first`.
    public func copy(from first: UInt64, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count * 2)
        let copied = out.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return duette_probe_recorder_copy(handle, first, base, count)
        }
        return Array(out.prefix(copied * 2))
    }

    /// One channel (0 left, 1 right) from recording index `first`.
    public func channel(_ index: Int, from first: UInt64, count: Int) -> [Float] {
        let stereo = copy(from: first, count: count)
        return stride(from: index, to: stereo.count, by: 2).map { stereo[$0] }
    }

    /// The latest `seconds` of one channel, or fewer if not recorded yet.
    public func latest(seconds: Double, channel index: Int = 0) -> [Float] {
        let total = frames
        let want = UInt64(min(Double(capacity - 1024), seconds * sampleRate))
        let first = total > want ? total - want : 0
        return channel(index, from: first, count: Int(total - first))
    }

    public func blocks() -> [IOBlock] {
        let count = cycles
        let start = count > UInt64(blockCapacity) ? count - UInt64(blockCapacity) : 0
        var result: [IOBlock] = []
        var raw = duette_probe_block()
        var index = start
        while index < count {
            if duette_probe_recorder_block(handle, index, &raw) { result.append(IOBlock(raw)) }
            index += 1
        }
        return result
    }
}

/// Plays into a device: silence, then (once armed) `signal`, then a tone or silence (see
/// duette_probe.h).
public final class ProbePlayer {
    public let device: AudioObjectID
    private let handle: OpaquePointer
    private static let blockCapacity = 16384
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, signal: [Float], tailHz: Double = 0, tailAmplitude: Float = 0,
                sampleRate: Double = 48000) throws {
        let capacity = Self.blockCapacity
        let created = signal.withUnsafeBufferPointer { buffer in
            duette_probe_player_create(buffer.baseAddress, buffer.count, capacity)
        }
        guard let handle = created else {
            throw CoreAudioError(OSStatus(kAudioHardwareUnspecifiedError), "allocate a player")
        }
        duette_probe_player_set_tail(handle, tailHz, tailAmplitude, sampleRate)
        self.device = device
        self.handle = handle
    }

    deinit {
        stop()
        duette_probe_player_destroy(handle)
    }

    public func start() throws {
        var proc: AudioDeviceIOProcID?
        let status = duette_probe_player_start(handle, device, &proc)
        guard status == kNoError, let proc else { throw CoreAudioError(status, "start playing into \(deviceName(device))") }
        procID = proc
    }

    /// The signal starts at the next cycle.
    public func arm() {
        duette_probe_player_arm(handle)
    }

    public func stop() {
        guard let procID else { return }
        _ = duette_probe_stop(device, procID)
        self.procID = nil
    }

    public var cycles: UInt64 { duette_probe_player_cycles(handle) }

    public func blocks() -> [IOBlock] {
        let count = cycles
        let capacity = UInt64(Self.blockCapacity)
        let start = count > capacity ? count - capacity : 0
        var result: [IOBlock] = []
        var raw = duette_probe_block()
        var index = start
        while index < count {
            if duette_probe_player_block(handle, index, &raw) { result.append(IOBlock(raw)) }
            index += 1
        }
        return result
    }
}

/// "Measure latency" on the real HAL: a short chirp into "Duette Sink", recorded from "Duette",
/// with both devices at the engine's buffer size. Nothing else may write to the sink meanwhile
/// (EngineController pauses the engine), and anyone recording "Duette" hears the chirp.
public enum LoopbackProbe {
    public static let chirpSeconds = 0.2
    /// -20 dBFS: the loopback is digital and exact, so a quiet chirp is found as surely as a loud
    /// one, and apps recording "Duette" hear only a soft sweep.
    public static let chirpAmplitude: Float = 0.1
    /// A take whose chirp was damaged (by a late I/O cycle) is repeated, at most this many times in all.
    public static let maxTakes = 3

    /// Whether a take can be trusted: the chirp was found cleanly, at the sample time it was
    /// written, and its latency measured.
    public static func isGood(_ result: LoopbackResult) -> Bool {
        result.confidence >= 0.9 && result.sampleOffset == 0 && result.latencyMean != nil
    }

    /// Runs `take` up to `attempts` times and returns the first take that `isGood`, with its
    /// attempt number. A take that throws counts as a failed attempt; if every one threw, the last
    /// error is thrown. Otherwise, with no good take, LatencyMeasurementError.notHeard.
    public static func pickTake(attempts: Int, take: () throws -> LoopbackResult?) throws -> (result: LoopbackResult, attempt: Int) {
        var lastError: Error?
        var completed = false
        for attempt in 1...max(1, attempts) {
            do {
                let result = try take()
                completed = true
                if let result, isGood(result) { return (result, attempt) }
            } catch {
                lastError = error
            }
        }
        if !completed, let lastError { throw lastError }
        throw LatencyMeasurementError.notHeard
    }

    /// Measures; blocks for about a second per take.
    public static func measure(sink: AudioObjectID, duette: AudioObjectID, bufferFrameSize: UInt32,
                               sampleRate: Double = 48000) throws -> LoopbackMeasurement {
        // Each process has its own buffer size on a device: these only change this process's IO.
        try AudioObject(sink).set(kAudioDevicePropertyBufferFrameSize, to: bufferFrameSize)
        try AudioObject(duette).set(kAudioDevicePropertyBufferFrameSize, to: bufferFrameSize)
        let chirp = Chirp.make(sampleRate: sampleRate, startHz: 200, endHz: 12000,
                               frames: Int(chirpSeconds * sampleRate), amplitude: chirpAmplitude)
        // Only a clean take is a result: a take whose chirp came back late, shifted or mangled
        // (the driver's test tone in its place, a late cycle) would give a wrong figure.
        let chosen = try pickTake(attempts: maxTakes) {
            try takeOnce(chirp: chirp, sink: sink, duette: duette, bufferFrameSize: bufferFrameSize, sampleRate: sampleRate)
        }
        guard let measurement = LoopbackMeasurement(result: chosen.result, bufferFrameSize: bufferFrameSize,
                                                    takes: chosen.attempt) else {
            throw LatencyMeasurementError.notHeard
        }
        return measurement
    }

    private static func takeOnce(chirp: [Float], sink: AudioObjectID, duette: AudioObjectID, bufferFrameSize: UInt32,
                                 sampleRate: Double) throws -> LoopbackResult? {
        let recorder = try ProbeRecorder(device: duette, seconds: 4, sampleRate: sampleRate)
        let player = try ProbePlayer(device: sink, signal: chirp, sampleRate: sampleRate)
        try recorder.start()
        defer { recorder.stop() }
        guard recorder.waitForFrames(UInt64(0.1 * sampleRate), timeout: 3) else {
            throw CoreAudioError(OSStatus(kAudioHardwareNotRunningError), "record from \(deviceName(duette)): no audio arrived")
        }
        try player.start()
        defer { player.stop() }
        // A few silent cycles first, so the chirp does not land on the writer's start-up.
        Thread.sleep(forTimeInterval: 0.1)
        player.arm()
        Thread.sleep(forTimeInterval: chirpSeconds + 0.15)
        player.stop()
        Thread.sleep(forTimeInterval: 0.05)
        recorder.stop()

        let total = recorder.frames
        let kept = min(total, UInt64(recorder.capacity))
        let first = total - kept
        let recording = recorder.channel(0, from: first, count: Int(kept))
        return LoopbackAnalysis.analyze(chirp: chirp, writer: player.blocks(), reader: recorder.blocks(),
                                        recording: recording, recordingStart: Int64(first),
                                        bufferFrames: Int(bufferFrameSize))
    }
}
