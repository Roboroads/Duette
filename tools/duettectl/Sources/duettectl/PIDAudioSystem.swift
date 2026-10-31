import CoreAudio
import DuetteAudio
import Foundation

/// The real CoreAudioSystem, plus apps named by process ID.
///
/// EngineController selects the app to tap by bundle ID and groups processes with
/// ProcessCatalog. A CLI process such as afplay has no app bundle, so duettectl passes the bundle
/// ID "pid:<n>": its "running application" is that process, and ProcessCatalog's parent and
/// responsible-process rules add its helpers as usual. Every other call goes to CoreAudioSystem
/// unchanged, so the controller runs exactly as it does in the app.
///
/// It also logs the calls that build and start the engine, and sets the watchdog stage before
/// each, so a call that never returns is named in the timeout.
final class PIDAudioSystem: AudioSystem {
    static let prefix = "pid:"

    static func bundleID(pid: pid_t) -> String { prefix + String(pid) }

    let base = CoreAudioSystem()
    /// The latest tap created, for reports.
    private(set) var lastTap: ProcessTap?
    private(set) var lastAggregate: AudioObjectID?
    private(set) var lastAggregateDescription: [String: Any]?
    private(set) var startIOCalls = 0

    var eventHandler: ((AudioSystemEvent) -> Void)? {
        get { base.eventHandler }
        set { base.eventHandler = newValue }
    }

    func deviceID(forUID uid: String) -> AudioObjectID? { base.deviceID(forUID: uid) }
    func devices() -> [AudioDeviceInfo] { base.devices() }
    func defaultInputDeviceUID() -> String? { base.defaultInputDeviceUID() }
    func nominalSampleRate(of device: AudioObjectID) -> Double? { base.nominalSampleRate(of: device) }

    func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo] {
        base.streams(of: device, scope: scope)
    }

    func aggregateStreams(_ aggregate: AudioObjectID, expectedInputs: Int,
                          expectedOutputs: Int) -> (input: [StreamInfo], output: [StreamInfo]) {
        base.aggregateStreams(aggregate, expectedInputs: expectedInputs, expectedOutputs: expectedOutputs)
    }

    func bufferChannels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]? {
        base.bufferChannels(of: device, scope: scope)
    }

    func processes() -> [AudioProcessInfo] { base.processes() }
    func runningApps() -> [RunningApp] { base.runningApps() }

    func runningApplicationPIDs(bundleID: String) -> [pid_t] {
        if bundleID.hasPrefix(Self.prefix), let pid = pid_t(bundleID.dropFirst(Self.prefix.count)) {
            return [pid]
        }
        return base.runningApplicationPIDs(bundleID: bundleID)
    }

    func parentPID(of pid: pid_t) -> pid_t? { base.parentPID(of: pid) }

    func systemAudioCaptureAuthorization() -> CaptureAuthorization { base.systemAudioCaptureAuthorization() }
    func systemAudioCaptureRawAnswer() -> Int32? { base.systemAudioCaptureRawAnswer() }
    func responsiblePID(of pid: pid_t) -> pid_t? { base.responsiblePID(of: pid) }
    func inputClientPIDs() -> [pid_t]? { base.inputClientPIDs() }

    func createTap(_ spec: TapSpec) throws -> ProcessTap {
        Stage.set("AudioHardwareCreateProcessTap for process objects \(spec.processObjectIDs)")
        do {
            let tap = try base.createTap(spec)
            lastTap = tap
            note("tap \(tap.id) uid \(tap.uid): \(tap.channels) ch at \(tap.sampleRate) Hz")
            return tap
        } catch {
            note("tap failed: \(error)")
            throw error
        }
    }

    func destroyTap(_ tapID: AudioObjectID) {
        base.destroyTap(tapID)
    }

    func createAggregate(_ description: [String: Any]) throws -> AudioObjectID {
        Stage.set("AudioHardwareCreateAggregateDevice (tap: \(description[kAudioAggregateDeviceTapListKey] != nil))")
        let aggregate = try base.createAggregate(description)
        lastAggregate = aggregate
        lastAggregateDescription = description
        note("aggregate \(aggregate) created")
        return aggregate
    }

    func destroyAggregate(_ aggregate: AudioObjectID) {
        base.destroyAggregate(aggregate)
    }

    func setBufferFrameSize(_ frames: UInt32, of device: AudioObjectID) throws {
        try base.setBufferFrameSize(frames, of: device)
    }

    func startIO(on device: AudioObjectID, engine: MixEngine) throws -> IOToken {
        startIOCalls += 1
        Stage.set("AudioDeviceCreateIOProcID + AudioDeviceStart on aggregate \(device) (tap: \(lastTap != nil))")
        let token = try base.startIO(on: device, engine: engine)
        note("IOProc started on aggregate \(device)")
        Stage.set("engine running")
        return token
    }

    func stopIO(_ token: IOToken) {
        Stage.set("AudioDeviceStop on aggregate \(token.device)")
        base.stopIO(token)
        Stage.set("engine stopped")
    }

    func watch(devices: [AudioObjectID], aggregate: AudioObjectID?) {
        base.watch(devices: devices, aggregate: aggregate)
    }

    func measureLoopback(sink: AudioObjectID, duette: AudioObjectID, bufferFrameSize: UInt32,
                         sampleRate: Double) throws -> LoopbackMeasurement {
        Stage.set("chirp through the sink into Duette at \(bufferFrameSize) frames (LoopbackProbe)")
        let measurement = try base.measureLoopback(sink: sink, duette: duette, bufferFrameSize: bufferFrameSize,
                                                   sampleRate: sampleRate)
        note(String(format: "loopback: %.1f frames mean, %.0f worst, offset %+.0f, confidence %.3f, %ld take(s)",
                    measurement.meanFrames, measurement.worstFrames, measurement.sampleOffset, measurement.confidence,
                    measurement.takes))
        return measurement
    }
}
