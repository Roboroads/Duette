import CoreAudio
import DuetteEngine

/// Where each source sits in the aggregate's buffer lists, for the engine.
public struct EngineLayout: Equatable, Codable {
    public var mic: BufferRange
    public var tap: BufferRange
    public var output: BufferRange
    public var sampleRate: Double

    public init(mic: BufferRange = .none, tap: BufferRange = .none, output: BufferRange, sampleRate: Double) {
        self.mic = mic
        self.tap = tap
        self.output = output
        self.sampleRate = sampleRate
    }

    /// The layout for a resolved aggregate: input ranges from `input`, the sink's from `output`.
    public init(input: StreamLayout, output: StreamLayout, sampleRate: Double) {
        self.init(mic: input.range(.mic), tap: input.range(.tap), output: output.range(.sink),
                  sampleRate: sampleRate)
    }
}

/// The engine's three gain stages.
public enum MixSource: String, CaseIterable, Codable {
    case app
    case mic
    case output

    var raw: duette_source {
        switch self {
        case .app: return DUETTE_SOURCE_APP
        case .mic: return DUETTE_SOURCE_MIC
        case .output: return DUETTE_SOURCE_OUTPUT
        }
    }
}

/// Level of the latest IOProc cycle, linear (1.0 is full scale).
public struct Level: Equatable, Codable {
    public var peak: Float
    public var rms: Float

    public init(peak: Float = 0, rms: Float = 0) {
        self.peak = peak
        self.rms = rms
    }

    init(_ raw: duette_level) {
        self.init(peak: raw.peak, rms: raw.rms)
    }
}

public struct Meters: Equatable, Codable {
    /// The app tap, before its gain.
    public var app: Level
    /// The mic, before its gain.
    public var mic: Level
    /// What goes to the sink.
    public var output: Level

    public init(app: Level = Level(), mic: Level = Level(), output: Level = Level()) {
        self.app = app
        self.mic = mic
        self.output = output
    }
}

/// Counters kept by the IOProc; see duette_stats in duette_engine.h.
public struct EngineStats: Equatable, Codable {
    public var cycles: UInt64 = 0
    public var frames: UInt64 = 0
    public var lastHostTime: UInt64 = 0
    public var tapZeroFrames: UInt64 = 0
    public var micZeroFrames: UInt64 = 0
    public var layoutMismatches: UInt64 = 0
    public var overloads: UInt64 = 0
    /// The tap delivered at least one non-zero sample since the engine was last configured.
    public var tapHadAudio = false

    public init() {}

    init(_ raw: duette_stats) {
        cycles = raw.cycles
        frames = raw.frames
        lastHostTime = raw.last_host_time
        tapZeroFrames = raw.tap_zero_frames
        micZeroFrames = raw.mic_zero_frames
        layoutMismatches = raw.layout_mismatches
        overloads = raw.overloads
        tapHadAudio = raw.tap_had_audio
    }
}

public enum MixEngineError: Error, Equatable {
    /// configure was called while the IOProc is running.
    case running
    /// The layout has no output buffers or no usable sample rate.
    case invalidLayout
}

/// The Swift face of the C++ engine (duette_engine.h). It owns one engine for the life of the
/// app; aggregates come and go around it.
public final class MixEngine {
    let handle: OpaquePointer

    public init() {
        guard let handle = duette_engine_create() else { fatalError("duette_engine_create failed: out of memory") }
        self.handle = handle
    }

    deinit {
        duette_engine_destroy(handle)
    }

    /// The engine as the IOProc's client data.
    public var clientData: UnsafeMutableRawPointer { UnsafeMutableRawPointer(handle) }

    public var isRunning: Bool { duette_engine_is_running(handle) }

    /// Sets the buffer layout. Only while stopped.
    public func configure(_ layout: EngineLayout) throws {
        var raw = duette_layout(mic: Self.raw(layout.mic), tap: Self.raw(layout.tap),
                                output: Self.raw(layout.output), sample_rate: layout.sampleRate)
        let status = duette_engine_configure(handle, &raw)
        if status == DUETTE_STATUS_OK { return }
        if status == DUETTE_STATUS_RUNNING { throw MixEngineError.running }
        throw MixEngineError.invalidLayout
    }

    /// Registers the engine's IOProc on `device` and starts it.
    public func start(on device: AudioObjectID) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = duette_engine_start(handle, device, &procID)
        guard status == kNoError, let started = procID else {
            throw CoreAudioError(status, "start the engine on device \(device)")
        }
        return started
    }

    /// Stops the IOProc and destroys it. Returns the first error, if any; the engine counts as
    /// stopped either way.
    @discardableResult
    public func stop(on device: AudioObjectID, procID: AudioDeviceIOProcID) -> OSStatus {
        duette_engine_stop(handle, device, procID)
    }

    /// Runs one IOProc cycle by hand on the calling thread, for tests and offline rendering.
    /// Never call it while the engine runs on a device.
    @discardableResult
    public func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                        hostTime: UInt64 = 0) -> OSStatus {
        var now = AudioTimeStamp()
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        if hostTime != 0 {
            outputTime.mHostTime = hostTime
            outputTime.mFlags = .hostTimeValid
        }
        return duette_engine_ioproc(0, &now, input, &inputTime, output, &outputTime, clientData)
    }

    /// Gains go from 0 to this (+6 dB).
    public static let maxGain: Float = 2

    /// Sets the gain of one stage, limited to 0...maxGain. Any thread.
    public func setGain(_ gain: Float, for source: MixSource) {
        duette_engine_set_gain(handle, source.raw, gain)
    }

    public func gain(for source: MixSource) -> Float {
        duette_engine_gain(handle, source.raw)
    }

    /// Mutes one stage, keeping its gain. Any thread.
    public func setMuted(_ muted: Bool, for source: MixSource) {
        duette_engine_set_mute(handle, source.raw, muted)
    }

    public func isMuted(_ source: MixSource) -> Bool {
        duette_engine_muted(handle, source.raw)
    }

    /// The engine's own 440 Hz test tone in place of the mix.
    public var testTone: Bool {
        get { duette_engine_test_tone(handle) }
        set { duette_engine_set_test_tone(handle, newValue) }
    }

    /// Levels of the latest cycle. Cheap; poll it from the UI.
    public func meters() -> Meters {
        var raw = duette_meters()
        duette_engine_read_meters(handle, &raw)
        return Meters(app: Level(raw.app), mic: Level(raw.mic), output: Level(raw.output))
    }

    public func stats() -> EngineStats {
        var raw = duette_stats()
        duette_engine_read_stats(handle, &raw)
        return EngineStats(raw)
    }

    /// Counts one processor overload of the aggregate.
    public func countOverload() {
        duette_engine_count_overload(handle)
    }

    static func raw(_ range: BufferRange) -> duette_range {
        duette_range(first: UInt32(clamping: max(range.first, 0)), count: UInt32(clamping: max(range.count, 0)))
    }
}
