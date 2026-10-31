import CoreAudio
import DuetteEngine

/// Where each source sits in the aggregate's buffer lists, for the engine.
public struct EngineLayout: Equatable, Codable {
    public var mic: BufferRange
    public var output: BufferRange
    public var sampleRate: Double

    public init(mic: BufferRange = .none, output: BufferRange, sampleRate: Double) {
        self.mic = mic
        self.output = output
        self.sampleRate = sampleRate
    }

    /// The layout for a resolved aggregate: input ranges from `input`, the sink's from `output`.
    public init(input: StreamLayout, output: StreamLayout, sampleRate: Double) {
        self.init(mic: input.range(.mic), output: output.range(.sink), sampleRate: sampleRate)
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
        var raw = duette_layout(mic: Self.raw(layout.mic), output: Self.raw(layout.output),
                                sample_rate: layout.sampleRate)
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

    static func raw(_ range: BufferRange) -> duette_range {
        duette_range(first: UInt32(clamping: max(range.first, 0)), count: UInt32(clamping: max(range.count, 0)))
    }
}
