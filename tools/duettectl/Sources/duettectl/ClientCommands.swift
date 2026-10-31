import AudioToolbox
import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

// Clients of "Duette" the way other apps read it: directly, through an aggregate device of their
// own (as Discord and other call apps do), or through the voice-processing I/O unit (VPIO), which
// builds such an aggregate itself. The driver's 'dcli' must name the app's process in every case,
// or the feedback-loop warning cannot work.

/// A private aggregate like the one a call app builds: its output device as the main
/// subdevice, "Duette" as the input with drift compensation.
final class ClientAggregate {
    let id: AudioObjectID

    init(inputUID: String, outputUID: String) throws {
        let subdevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey: outputUID],
            [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1],
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "duettectl client",
            kAudioAggregateDeviceUIDKey: "me.roboroads.duette.duettectl-client.\(getpid())",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]
        Stage.set("create the client aggregate")
        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == 0, aggregate != 0 else { throw CoreAudioError(status, "create the client aggregate") }
        id = aggregate
        // The HAL fills in the streams shortly after creating the aggregate.
        waitUntil(3, interval: 0.05) {
            ((try? AudioObject(aggregate).bufferChannels(scope: kAudioObjectPropertyScopeInput)) ?? []).reduce(0, +) > 0
        }
    }

    var inputChannels: [Int] { (try? AudioObject(id).bufferChannels(scope: kAudioObjectPropertyScopeInput)) ?? [] }

    deinit {
        _ = AudioHardwareDestroyAggregateDevice(id)
    }
}

/// The voice-processing I/O unit with the system default devices, input enabled.
final class VoiceProcessingClient {
    private var unit: AudioUnit?
    private(set) var started = false

    init() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw ToolError("no VoiceProcessingIO audio unit here")
        }
        var instance: AudioComponentInstance?
        Stage.set("AudioComponentInstanceNew (VoiceProcessingIO)")
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == 0, let instance else { throw CoreAudioError(status, "create the VoiceProcessingIO unit") }
        unit = instance
        var one: UInt32 = 1
        status = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                      &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == 0 else { throw CoreAudioError(status, "enable VoiceProcessingIO input") }
        Stage.set("AudioUnitInitialize (VoiceProcessingIO)")
        status = AudioUnitInitialize(instance)
        guard status == 0 else { throw CoreAudioError(status, "initialize VoiceProcessingIO") }
        Stage.set("AudioOutputUnitStart (VoiceProcessingIO)")
        status = AudioOutputUnitStart(instance)
        guard status == 0 else { throw CoreAudioError(status, "start VoiceProcessingIO") }
        started = true
    }

    /// The device the unit says it uses for `element` (1 input, 0 output).
    func currentDevice(element: AudioUnitElement) -> AudioObjectID? {
        guard let unit else { return nil }
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element,
                                          &device, &size)
        return status == 0 && device != 0 ? device : nil
    }

    func stop() {
        guard let unit else { return }
        if started { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        started = false
    }

    deinit {
        stop()
    }
}

/// Reads "Duette" one way, and keeps the objects alive while it does.
final class DuetteReader {
    private var recorder: Recorder?
    private var player: Player?
    private var aggregate: ClientAggregate?
    private var vpio: VoiceProcessingClient?
    private let defaults = DefaultDevices()
    let mode: String

    init(mode: String, playHz: Double = 0) throws {
        self.mode = mode
        let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
        switch mode {
        case "direct":
            let recorder = try Recorder(device: duette, seconds: 5)
            try recorder.start()
            self.recorder = recorder
        case "aggregate":
            _ = try Device.require(uid: DuetteDriver.testSpeakerUID, timeout: 10)
            let aggregate = try ClientAggregate(inputUID: DuetteDriver.deviceUID, outputUID: DuetteDriver.testSpeakerUID)
            self.aggregate = aggregate
            note("client aggregate \(aggregate.id): input buffers \(aggregate.inputChannels)")
            let recorder = try Recorder(device: aggregate.id, seconds: 5)
            Stage.set("start IO on the client aggregate")
            try recorder.start()
            self.recorder = recorder
            if playHz > 0 {
                let player = try Player(device: aggregate.id, signal: [], tailHz: playHz, tailAmplitude: 0.25)
                try player.start()
                player.arm()
                self.player = player
            }
        case "vpio":
            let speaker = try Device.require(uid: DuetteDriver.testSpeakerUID, timeout: 10)
            try defaults.set(kAudioHardwarePropertyDefaultInputDevice, to: duette)
            try defaults.set(kAudioHardwarePropertyDefaultOutputDevice, to: speaker)
            vpio = try VoiceProcessingClient()
        default:
            throw ToolError("unknown reader mode '\(mode)': direct, aggregate or vpio")
        }
    }

    var frames: UInt64 { recorder?.frames ?? 0 }
    func latest(seconds: Double) -> [Float] { recorder?.latest(seconds: seconds) ?? [] }
    var vpioDevices: (input: AudioObjectID?, output: AudioObjectID?) {
        (vpio?.currentDevice(element: 1), vpio?.currentDevice(element: 0))
    }

    func stop() {
        player?.stop()
        recorder?.stop()
        vpio?.stop()
        player = nil
        recorder = nil
        vpio = nil
        aggregate = nil
        defaults.restore()
    }

    deinit {
        stop()
    }
}

func clients() -> [pid_t] { HAL.driverInputClients() ?? [] }

func processName(_ pid: pid_t) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "comm=", "-p", String(pid)]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "?" }
    process.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func describeClients(_ pids: [pid_t]) -> String {
    pids.isEmpty ? "[]" : "[" + pids.map { "\($0) \(processName($0))" }.joined(separator: ", ") + "]"
}

// MARK: - reader (helper)

func runReader(_ ctx: Context) throws {
    let reader = try DuetteReader(mode: ctx.string("mode") ?? "aggregate", playHz: ctx.double("play-hz") ?? 0)
    print("READY pid=\(getpid())")
    idle(ctx.double("seconds") ?? 60)
    reader.stop()
}

/// `duettectl reader` in a process of its own: another app reading "Duette". Stopped when it goes
/// away, and by the watchdog.
final class ReaderProcess {
    let process = Process()
    private var cleanup: Int?

    init(mode: String, playHz: Double = 0) throws {
        guard let executable = Bundle.main.executableURL else { throw ToolError("cannot find duettectl's own path") }
        process.executableURL = executable
        process.arguments = ["reader", "--mode", mode, "--seconds", "90", "--play-hz", String(playHz), "--timeout", "0"]
        Stage.set("start a reader process (\(mode))")
        try process.run()
        cleanup = Cleanup.add(process)
    }

    var pid: pid_t { process.processIdentifier }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if let cleanup { Cleanup.remove(cleanup) }
        cleanup = nil
    }

    deinit {
        stop()
    }
}

/// What the HAL's own process object says about `pid`, next to 'dcli': whether it runs input IO
/// and which devices it uses.
func halView(of pid: pid_t) -> String {
    guard let object = HAL.processObjectID(forPID: pid) else { return "\(pid): no process object" }
    let info = HAL.processInfo(object)
    func devices(_ scope: AudioObjectPropertyScope) -> String {
        let ids = (try? AudioObject(object).getArray(kAudioProcessPropertyDevices, scope: scope, of: AudioObjectID.self)) ?? []
        return "[" + ids.map { Device.name($0) }.joined(separator: ", ") + "]"
    }
    return "\(pid): running input \(info?.isRunningInput ?? false), output \(info?.isRunningOutput ?? false); "
        + "devices input \(devices(kAudioObjectPropertyScopeInput)), output \(devices(kAudioObjectPropertyScopeOutput))"
}

// MARK: - dcli

func runDcli(_ ctx: Context) throws {
    let r = ctx.reporter
    let mode = ctx.string("mode") ?? "aggregate"
    let me = getpid()
    _ = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    if mode == "aggregate" || mode == "vpio", Device.find(uid: DuetteDriver.testSpeakerUID, timeout: 10) == nil {
        r.skip("\(mode)", "no test speaker", detail: "needs the driver built with DUETTE_TEST_DEVICES=ON")
        return
    }
    try? HAL.setDriverSelfTestTone(false)
    r.check("idle", HAL.driverInputClients() != nil && !clients().contains(me), describeClients(clients()),
            detail: "'dcli' before this process reads Duette")

    if mode == "concurrent" {
        try runConcurrentReaders(r, me: me)
        return
    }

    let reader: DuetteReader
    do {
        reader = try DuetteReader(mode: mode)
    } catch {
        r.check("\(mode).start", false, "\(error)", detail: "at: \(Stage.value)")
        return
    }
    if mode == "vpio" {
        let devices = reader.vpioDevices
        r.info("vpio.devices", "input \(devices.input.map(Device.name) ?? "?"), output \(devices.output.map(Device.name) ?? "?")")
    }
    let listed = waitUntil(5, interval: 0.05) { clients().contains(me) }
    r.check("\(mode).lists-pid", listed, describeClients(clients()), detail: "this process is \(me); HAL: \(halView(of: me))")

    if mode != "vpio" {
        // The reader really gets "Duette": turn on the driver's tone and look for it.
        try HAL.setDriverSelfTestTone(true)
        idle(1)
        r.tones("\(mode).audio", reader.latest(seconds: 0.5), expect: [.at(toneHz, dbfsMinus12)])
        try HAL.setDriverSelfTestTone(false)
    }
    reader.stop()
    let cleared = waitUntil(5, interval: 0.05) { !clients().contains(me) }
    r.check("\(mode).clears", cleared, describeClients(clients()), detail: "after this process stops reading")
}

/// Two processes reading "Duette" directly at the same time: 'dcli' must list both, the second
/// as well as the first, and drop each when it stops.
func runConcurrentReaders(_ r: Reporter, me: pid_t) throws {
    let other = try ReaderProcess(mode: "direct")
    defer { other.stop() }
    let first = waitUntil(10, interval: 0.05) { clients().contains(other.pid) }
    r.check("concurrent.first-listed", first, describeClients(clients()), detail: "the other reader is \(other.pid)")

    let mine = try DuetteReader(mode: "direct")
    let flowing = waitUntil(5) { mine.frames >= 4800 }
    r.check("concurrent.second-runs", flowing, "\(mine.frames) frames", detail: "this process's IOProc on Duette gets audio")
    let second = waitUntil(5, interval: 0.05) { clients().contains(me) && clients().contains(other.pid) }
    r.check("concurrent.second-listed", second, describeClients(clients()),
            detail: "this process is \(me), started second; HAL: \(halView(of: me)) / \(halView(of: other.pid))")

    mine.stop()
    let dropped = waitUntil(5, interval: 0.05) { !clients().contains(me) && clients().contains(other.pid) }
    r.check("concurrent.second-clears", dropped, describeClients(clients()), detail: "this process stopped; the other still reads")
    other.stop()
    let cleared = waitUntil(5, interval: 0.05) { !clients().contains(other.pid) }
    r.check("concurrent.clears", cleared, describeClients(clients()))
}

// MARK: - feedback-loop

func runFeedbackLoop(_ ctx: Context) throws {
    let r = ctx.reporter
    let me = getpid()
    _ = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    guard Device.find(uid: DuetteDriver.testSpeakerUID, timeout: 10) != nil else {
        r.skip("test-devices", "no test speaker", detail: "needs the driver built with DUETTE_TEST_DEVICES=ON")
        return
    }
    try? HAL.setDriverSelfTestTone(false)

    // Duette itself reads "Duette" too (the app's "Measure latency", for example). It is listed in
    // 'dcli' and must never count as a loop.
    let own = try Recorder(device: try Device.require(uid: DuetteDriver.deviceUID), seconds: 2)
    try own.start()
    defer { own.stop() }
    let ownListed = waitUntil(5, interval: 0.05) { clients().contains(me) }
    r.check("dcli.lists-own-process", ownListed, describeClients(clients()), detail: "this process is \(me)")

    // The "call app": another process that plays 440 Hz and records "Duette" through its own
    // aggregate, as Discord does when Duette is its microphone.
    let child = try ReaderProcess(mode: "aggregate", playHz: 440)
    defer { child.stop() }
    let app = child.pid
    let listed = waitUntil(15, interval: 0.1) { clients().contains(app) && clients().contains(me) }
    r.check("dcli.lists-app", listed, describeClients(clients()), detail: "the reader process is \(app); this process \(me) still reads")

    let system = PIDAudioSystem()
    let bundleID = PIDAudioSystem.bundleID(pid: app)
    func group() -> Set<pid_t> {
        Set(ProcessCatalog.processes(of: bundleID, in: system.processes(),
                                     appPIDs: Set(system.runningApplicationPIDs(bundleID: bundleID)),
                                     parentPID: system.parentPID, responsiblePID: system.responsiblePID,
                                     excludingPID: me).map(\.pid))
    }
    let appPIDs = group()
    r.check("catalog.groups-app", appPIDs.contains(app) && !appPIDs.contains(me), "\(appPIDs.sorted())",
            detail: "ProcessCatalog for the tapped app; never this process (\(me))")
    let inputClients = system.inputClientPIDs() ?? []
    let looping = FeedbackLoopDetector.loopingPIDs(inputClients: inputClients, appPIDs: appPIDs, ownPID: me)
    r.check("detector.fires", looping == [app], "\(looping)", detail: "FeedbackLoopDetector with the live 'dcli' \(inputClients)")
    // Even when this process is wrongly counted as part of the app, it is not a loop.
    let withOwn = FeedbackLoopDetector.loopingPIDs(inputClients: inputClients, appPIDs: appPIDs.union([me]), ownPID: me)
    r.check("detector.ignores-own-process", inputClients.contains(me) && withOwn == [app], "\(withOwn)",
            detail: "'dcli' \(inputClients) holds this process (\(me)); it is left out")
    own.stop()

    if ctx.flag("controller") {
        // EngineController taps the app and raises the warning itself.
        let run = EngineRun()
        run.start(app: bundleID, mic: .none, buffer: ctx.buffer)
        if r.engineRunning(run, .appOnly, timeout: 30) != nil {
            let raised = waitUntil(5) { run.controller.status.feedbackLoop }
            let status = run.controller.status
            r.check("controller.warns", raised && status.feedbackLoopPIDs == [app], "feedbackLoop \(status.feedbackLoop), pids \(status.feedbackLoopPIDs)")
        }
        child.stop()
        let cleared = waitUntil(10) { !run.controller.status.feedbackLoop }
        r.check("controller.clears", cleared, "feedbackLoop \(run.controller.status.feedbackLoop)", detail: "after the app quits")
        run.stop()
    }

    child.stop()
    let gone = waitUntil(10, interval: 0.1) { !clients().contains(app) }
    r.check("dcli.clears-when-app-quits", gone, describeClients(clients()))
    let after = FeedbackLoopDetector.loopingPIDs(inputClients: clients(), appPIDs: appPIDs, ownPID: me)
    r.check("detector.quiet-after", after.isEmpty, "\(after)")
}
