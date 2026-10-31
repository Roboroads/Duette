import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

func micSelection(_ mic: MicArgument) -> MicSelection {
    switch mic {
    case .none: return .device(uid: "me.roboroads.duette.duettectl.no-mic")
    case .systemDefault: return .systemDefault
    case .testMic: return .device(uid: DuetteDriver.testMicUID)
    case .uid(let uid): return .device(uid: uid)
    }
}

func describe(_ state: EngineState) -> String {
    switch state {
    case .idle: return "idle"
    case .waitingForDriver: return "waiting for the driver"
    case .waitingForApp(let bundleID): return "waiting for \(bundleID)"
    case .running(let sources): return "running (\(sources.rawValue))"
    case .error(let status, let attempt): return "error \(FourCC.describe(status)), attempt \(attempt)"
    }
}

func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}

/// EngineController on the real HAL, as the app runs it.
final class EngineRun {
    let system = PIDAudioSystem()
    let controller: EngineController
    let overloads = OverloadLog()
    var engine: MixEngine { controller.engine }

    init() {
        controller = EngineController(audioSystem: system)
    }

    func start(app: String?, mic: MicArgument, buffer: UInt32) {
        let configuration = EngineConfiguration(appBundleID: app, mic: micSelection(mic), bufferFrameSize: buffer)
        note("engine: start with \(json(configuration))")
        controller.onStatusChange = { status in note("engine: \(describe(status.state))") }
        controller.start(configuration)
    }

    /// Waits for the controller to run with these sources; nil on timeout.
    func waitForRunning(_ sources: EngineSources, timeout: Double) -> EngineStatus? {
        var reached: EngineStatus?
        waitUntil(timeout, interval: 0.05) {
            let status = controller.status
            if status.state == .running(sources) { reached = status }
            return reached != nil
        }
        return reached
    }

    func stop() {
        controller.stop()
        waitUntil(5) { controller.status.state == .idle }
    }

    deinit {
        controller.stop()
    }
}

/// Notes every kAudioDeviceProcessorOverload of the watched devices as it happens, so a glitch
/// in a recording can be matched to a cycle the HAL says was late.
final class OverloadLog {
    private var listeners: [PropertyListener] = []
    private let queue = DispatchQueue(label: "me.roboroads.duette.duettectl.overloads")
    private let lock = NSLock()
    private var counts: [AudioObjectID: Int] = [:]
    private var stamps: [Date] = []

    func watch(_ device: AudioObjectID, name: String) {
        let listener = try? PropertyListener(objectID: device, selector: kAudioDeviceProcessorOverload, queue: queue) { [weak self] in
            self?.hit(device, name)
        }
        if let listener { listeners.append(listener) }
    }

    private func hit(_ device: AudioObjectID, _ name: String) {
        lock.lock()
        let count = (counts[device] ?? 0) + 1
        counts[device] = count
        stamps.append(Date())
        lock.unlock()
        note("overload #\(count) on \(name)")
    }

    func count(_ device: AudioObjectID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[device] ?? 0
    }

    /// When each overload was reported, any device.
    var times: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return stamps
    }

    /// All watched devices together.
    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    func cancel() {
        for listener in listeners { listener.cancel() }
        listeners = []
    }

    deinit {
        cancel()
    }
}

/// How the measurement windows of a command went: taken clean at once, clean after retakes, or
/// never clean.
enum WindowLog {
    private(set) static var windows = 0
    private(set) static var retaken = 0
    private(set) static var neverClean = 0
    private(set) static var attempts = 0
    /// Whether the latest window was clean.
    private(set) static var lastClean = true

    static func record(attempts used: Int, clean: Bool) {
        lastClean = clean
        windows += 1
        attempts += used
        if used > 1 { retaken += 1 }
        if !clean { neverClean += 1 }
    }
}

extension Recorder {
    /// A window that no late I/O cycle damaged: no run of 32 or more exact zeros, and no overload
    /// while it was recorded. Up to `attempts` tries; if none is clean, the least damaged (counted
    /// in Reporter.engineStats). Only for windows that should never be silent: a level measured
    /// over a dropout reads low.
    func cleanTake(seconds: Double, settle: Double = 0.2, overloads: OverloadLog, channel: Int = 0,
                   attempts: Int = 8) -> [Float] {
        var best: (samples: [Float], damage: Int)?
        for attempt in 1...attempts {
            let before = overloads.total
            let samples = take(seconds: seconds, settle: attempt == 1 ? settle : 0, channel: channel)
            let late = overloads.total - before
            let stats = SignalStats(samples)
            let run = stats.longestZeroRun >= 32 ? stats.zeros : 0
            if late == 0 && run == 0 {
                WindowLog.record(attempts: attempt, clean: true)
                return samples
            }
            // Missing frames weigh most; an overload that left no gap is a small blemish.
            let damage = run * 10 + late
            if best == nil || damage < best!.damage { best = (samples, damage) }
            note("window damaged (\(late) overloads, \(stats.longestZeroRun)-frame zero run); recording it again")
        }
        WindowLog.record(attempts: attempts, clean: false)
        return best?.samples ?? []
    }
}

extension Reporter {
    /// The state check every engine command starts with.
    @discardableResult
    func engineRunning(_ run: EngineRun, _ sources: EngineSources, timeout: Double = 20, prefix: String = "") -> EngineStatus? {
        Stage.set("waiting for the engine to run (\(sources.rawValue))")
        let status = run.waitForRunning(sources, timeout: timeout)
        let now = run.controller.status
        check(prefix + "state", status != nil, describe(now.state),
              detail: "want running (\(sources.rawValue)); last error \(now.lastError.map { "\($0)" } ?? "none")")
        if let status {
            note("engine status: \(json(status))")
            if let aggregate = status.aggregateID { run.overloads.watch(aggregate, name: "the engine's aggregate") }
        }
        return status
    }

    /// The engine's counters. Overloads gate only the soak (`overloadsBlock`): a short run on a
    /// shared CI machine gets the odd late cycle, which the soak measures properly.
    func engineStats(_ run: EngineRun, overloadsBlock: Bool = false, prefix: String = "") {
        let stats = run.engine.stats()
        info(prefix + "stats", "\(stats.cycles) cycles, \(stats.frames) frames",
             detail: "tap zero run \(stats.tapZeroFrames), mic zero run \(stats.micZeroFrames), tap had audio \(stats.tapHadAudio)")
        let detail = "kAudioDeviceProcessorOverload on the aggregate"
        if overloadsBlock {
            check(prefix + "overloads", stats.overloads == 0, "\(stats.overloads)", detail: detail)
        } else {
            info(prefix + "overloads", "\(stats.overloads)", detail: detail)
        }
        check(prefix + "layout-mismatches", stats.layoutMismatches == 0, "\(stats.layoutMismatches)",
              detail: "cycles whose buffer lists did not fit the resolved layout")
        // Reported, not gated: on the CI machine a window now and then stays damaged through five
        // takes, and its levels are then measured on the least damaged one.
        if WindowLog.windows > 0 {
            info("windows.clean", "\(WindowLog.windows - WindowLog.neverClean) of \(WindowLog.windows) clean",
                 detail: "\(WindowLog.retaken) needed a retake, \(WindowLog.attempts) takes in all; a window with an overload or a dropout is taken again, at most 8 times")
        }
    }

    /// Everything in a recording but the expected tones: noise, clicks, resampling artefacts.
    func residual(_ name: String, _ samples: [Float], tones frequencies: [Double], limit: Double = -55) {
        guard let spectrum = Spectrum(samples: samples, sampleRate: Device.sampleRate) else {
            check(name, false, "too short to analyse")
            return
        }
        let residual = spectrum.residualDBFS(excluding: frequencies.compactMap { spectrum.tone(near: $0) })
        check(name, residual <= limit, Format.db(residual), detail: String(format: "everything but the tones, limit %.0f dBFS", limit))
    }

    /// Dropouts in a recording, reported with where the longest one starts.
    func dropouts(_ name: String, _ samples: [Float], blocking: Bool = false) {
        let stats = SignalStats(samples)
        let value = "longest zero run \(stats.longestZeroRun) frames"
        let detail = stats.longestZeroRun > 0
            ? String(format: "starts %.3f s into the %.2f s window", Double(stats.longestZeroRunStart) / Device.sampleRate,
                     Double(samples.count) / Device.sampleRate)
            : "none"
        if blocking {
            check(name, stats.longestZeroRun < 32, value, detail: detail)
        } else {
            info(name, value, detail: detail)
        }
    }

    func meter(_ name: String, _ level: Level, dbfs expected: Double) {
        let measured = ToneMeasurement.dbfs(Double(level.peak))
        check("meter.\(name)", abs(measured - expected) <= ToneExpectation.defaultToleranceDB, Format.db(measured),
              detail: String(format: "peak of the latest cycle, want %.1f dBFS; rms %.4f", expected, level.rms))
    }
}

// MARK: - engine

func runEngine(_ ctx: Context) throws {
    let r = ctx.reporter
    let mic = MicArgument(ctx.string("mic") ?? "test-mic")
    var app = ctx.string("app")
    if let pid = ctx.int("pid") { app = PIDAudioSystem.bundleID(pid: pid_t(pid)) }
    let seconds = ctx.double("seconds") ?? 3
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)

    let run = EngineRun()
    run.start(app: app, mic: mic, buffer: ctx.buffer)
    defer { run.stop() }
    let sources = EngineSources(mic: mic != .none, app: app != nil)
    guard r.engineRunning(run, sources) != nil else { return }
    if ctx.flag("test-tone") { run.engine.testTone = true }

    let recorder = try Recorder(device: duette, seconds: seconds + 2)
    run.overloads.watch(duette, name: "Duette (this reader)")
    try recorder.start()
    idle(seconds)
    recorder.stop()
    let samples = recorder.latest(seconds: max(0.5, seconds - 0.3))
    if let path = ctx.string("record") {
        let stereo = recorder.copy(from: 0, count: Int(recorder.frames))
        try WAVAudio(sampleRate: Device.sampleRate, channels: 2, samples: stereo).write(to: URL(fileURLWithPath: path))
        r.info("recorded", "\(stereo.count / 2) frames", detail: path)
    }
    if let expect = ctx.string("expect") {
        r.tones("duette", samples, expect: try ToneExpectation.parseList(expect))
    }
    let meters = run.engine.meters()
    r.info("meters", String(format: "app %.4f, mic %.4f, output %.4f (peak)", meters.app.peak, meters.mic.peak, meters.output.peak))
    r.engineStats(run)
}

// MARK: - verify-mic

func runVerifyMic(_ ctx: Context) throws {
    let r = ctx.reporter
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    guard Device.find(uid: DuetteDriver.testMicUID, timeout: 10) != nil else {
        r.skip("test-mic", "not found", detail: "needs the driver built with DUETTE_TEST_DEVICES=ON")
        return
    }
    try? HAL.setDriverSelfTestTone(false)
    let run = EngineRun()
    run.start(app: nil, mic: .testMic, buffer: ctx.buffer)
    defer { run.stop() }
    guard let status = r.engineRunning(run, .micOnly) else { return }
    r.info("layout", status.layout.map { json($0) } ?? "none", detail: "input by \(status.inputLayoutMethod?.rawValue ?? "?"), output by \(status.outputLayoutMethod?.rawValue ?? "?")")

    let recorder = try Recorder(device: duette, seconds: 30)
    run.overloads.watch(duette, name: "Duette (this reader)")
    Stage.set("recording Duette")
    try recorder.start()
    defer { recorder.stop() }
    recorder.waitForFrames(4800, timeout: 5)

    // M2: the test mic's 1 kHz (on a clock 200 ppm fast) arrives at its level, resampled to the
    // sink's clock by the aggregate's drift compensation.
    let plain = recorder.cleanTake(seconds: 2, settle: 0.5, overloads: run.overloads)
    r.tones("mic", plain, expect: [.at(testMicHz, dbfsMinus12), .absent(toneHz, below: absentDBFS)], damaged: !WindowLog.lastClean)
    r.residual("mic.residual", plain, tones: [testMicHz])
    let right = recorder.cleanTake(seconds: 1, overloads: run.overloads, channel: 1)
    r.tones("mic.right", right, expect: [.at(testMicHz, dbfsMinus12)])
    r.dropouts("mic.dropouts", plain)
    let meters = run.engine.meters()
    r.meter("mic", meters.mic, dbfs: dbfsMinus12)
    r.meter("output", meters.output, dbfs: dbfsMinus12)

    // M4: gain, mute and the output stage.
    run.engine.setGain(0.5, for: .mic)
    r.tones("mic-gain-0.5", recorder.cleanTake(seconds: 1, overloads: run.overloads), expect: [.at(testMicHz, dbfsMinus12 - 6.0206)])
    run.engine.setGain(1, for: .mic)
    run.engine.setMuted(true, for: .mic)
    let muted = recorder.take(seconds: 1, settle: 0.2)
    let mutedStats = SignalStats(muted)
    r.check("mic-mute.silence", !muted.isEmpty && mutedStats.peak == 0, String(format: "peak %.6f", mutedStats.peak),
            detail: "a muted mic and no app give exact zeros")
    r.meter("mic-while-muted", run.engine.meters().mic, dbfs: dbfsMinus12)
    run.engine.setMuted(false, for: .mic)
    run.engine.setGain(2, for: .output)
    r.tones("output-gain-2", recorder.cleanTake(seconds: 1, overloads: run.overloads), expect: [.at(testMicHz, dbfsMinus12 + 6.0206)])
    run.engine.setGain(1, for: .output)

    // The engine's own test tone replaces the mix.
    run.engine.testTone = true
    r.tones("engine-tone", recorder.cleanTake(seconds: 1, overloads: run.overloads), expect: [.at(toneHz, dbfsMinus12), .absent(testMicHz, below: absentDBFS)], damaged: !WindowLog.lastClean)
    run.engine.testTone = false
    r.tones("after-tone", recorder.cleanTake(seconds: 1, overloads: run.overloads), expect: [.at(testMicHz, dbfsMinus12), .absent(toneHz, below: absentDBFS)], damaged: !WindowLog.lastClean)
    r.engineStats(run)
}

// MARK: - hidden-agg

func runHiddenAggregate(_ ctx: Context) throws {
    let r = ctx.reporter
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    let sink = try Device.require(uid: DuetteDriver.sinkUID, timeout: 10)
    r.check("sink.hidden", Device.isHidden(sink) && !Device.isListed(sink),
            "IsHidden \(Device.isHidden(sink)), in the device list \(Device.isListed(sink))")
    try? HAL.setDriverSelfTestTone(false)

    let run = EngineRun()
    run.start(app: nil, mic: .none, buffer: ctx.buffer)
    defer { run.stop() }
    guard let status = r.engineRunning(run, .none), let aggregate = status.aggregateID else { return }

    let object = AudioObject(aggregate)
    let main = (try? object.getCFObject(kAudioAggregateDevicePropertyMainSubDevice)) as? String
    let clock = (try? object.getCFObject(kAudioAggregateDevicePropertyClockDevice)) as? String
    let members = (try? object.getCFObject(kAudioAggregateDevicePropertyFullSubDeviceList)) as? [String]
    r.check("main-subdevice", main == DuetteDriver.sinkUID, main ?? "unreadable", detail: "kAudioAggregateDevicePropertyMainSubDevice")
    r.check("clock-device", clock == DuetteDriver.sinkUID, clock ?? "unreadable", detail: "kAudioAggregateDevicePropertyClockDevice")
    r.info("subdevices", members.map { $0.joined(separator: ", ") } ?? "unreadable")
    r.info("aggregate", "id \(aggregate), \(Int(status.sampleRate ?? 0)) Hz, buffer \(Device.bufferFrameSize(aggregate) ?? 0) frames",
           detail: "output \(Device.timing(aggregate, scope: kAudioObjectPropertyScopeOutput))")

    let before = run.engine.stats()
    let started = Date()
    idle(1)
    let after = run.engine.stats()
    let elapsed = Date().timeIntervalSince(started)
    let cycles = after.cycles - before.cycles
    let framesPerSecond = Double(after.frames - before.frames) / elapsed
    r.check("ioproc-runs", cycles > 0 && abs(framesPerSecond - Device.sampleRate) < 0.05 * Device.sampleRate,
            String(format: "%.0f frames/s", framesPerSecond),
            detail: "\(cycles) cycles in \(String(format: "%.2f", elapsed)) s; the sink's clock is 48000 Hz")

    // What the engine writes to the hidden sink comes out of "Duette".
    let recorder = try Recorder(device: duette, seconds: 10)
    run.overloads.watch(duette, name: "Duette (this reader)")
    try recorder.start()
    defer { recorder.stop() }
    recorder.waitForFrames(4800, timeout: 5)
    let silent = recorder.take(seconds: 0.5, settle: 0.2)
    r.check("silence-before-tone", !silent.isEmpty && SignalStats(silent).peak == 0, String(format: "peak %.6f", SignalStats(silent).peak),
            detail: "no mic and no app: the engine writes zeros")
    run.engine.testTone = true
    r.tones("engine-tone", recorder.cleanTake(seconds: 1, settle: 0.3, overloads: run.overloads), expect: [.at(toneHz, dbfsMinus12)])
    run.engine.testTone = false
    r.engineStats(run)
}

// MARK: - verify-mix and rate-mismatch

/// Starts afplay with a 440 Hz tone and waits until the HAL sees it playing.
final class TonePlayback {
    let process = Process()
    let url: URL
    private var cleanup: Int?

    init(rate: Double, seconds: Double = 90) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("duettectl-440-\(Int(rate)).wav")
        let tone = Sine.make(frequency: toneHz, dbfs: dbfsMinus12, sampleRate: rate, seconds: seconds)
        try WAVAudio(sampleRate: rate, channels: 2, samples: Sine.interleave([tone, tone])).write(to: url, as: .pcm16)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        Stage.set("start afplay")
        try process.run()
        cleanup = Cleanup.add(process)
    }

    var pid: pid_t { process.processIdentifier }

    /// Waits until afplay's process object is running output.
    func waitUntilPlaying(timeout: Double) -> Bool {
        waitUntil(timeout, interval: 0.1) {
            guard let object = HAL.processObjectID(forPID: pid) else { return false }
            return HAL.processInfo(object)?.isRunningOutput ?? false
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if let cleanup { Cleanup.remove(cleanup) }
        cleanup = nil
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        stop()
    }
}

func runVerifyMix(_ ctx: Context, speakerRate: Double) throws {
    let r = ctx.reporter
    let expectDenied = ctx.flag("expect-denied")
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    guard Device.find(uid: DuetteDriver.testMicUID, timeout: 10) != nil,
          let speaker = Device.find(uid: DuetteDriver.testSpeakerUID, timeout: 10) else {
        r.skip("test-devices", "not found", detail: "needs the driver built with DUETTE_TEST_DEVICES=ON")
        return
    }
    try? HAL.setDriverSelfTestTone(false)

    // afplay plays into the test speaker at `speakerRate`; its tap runs at that rate.
    let defaults = DefaultDevices()
    let rateCleanup = Cleanup.add("test speaker back to 48 kHz") {
        try? AudioObject(speaker).set(kAudioDevicePropertyNominalSampleRate, to: Float64(48000))
    }
    defer {
        defaults.restore()
        try? Device.setNominalRate(speaker, 48000)
        Cleanup.remove(rateCleanup)
    }
    Stage.set("test speaker to \(Int(speakerRate)) Hz")
    try Device.setNominalRate(speaker, speakerRate)
    try defaults.set(kAudioHardwarePropertyDefaultOutputDevice, to: speaker)
    r.info("speaker", "'\(Device.name(speaker))' at \(Int(Device.nominalRate(speaker) ?? 0)) Hz, default output")

    let afplay = try TonePlayback(rate: speakerRate)
    defer { afplay.stop() }
    Stage.set("waiting for afplay (pid \(afplay.pid)) to play")
    r.check("afplay.playing", afplay.waitUntilPlaying(timeout: 10), "pid \(afplay.pid)",
            detail: "its process object reports IsRunningOutput")

    let run = EngineRun()
    run.start(app: PIDAudioSystem.bundleID(pid: afplay.pid), mic: .testMic, buffer: ctx.buffer)
    defer { run.stop() }
    guard let status = r.engineRunning(run, .both, timeout: 30) else { return }
    r.check("tapped", status.tappedPIDs.contains(afplay.pid), "\(status.tappedPIDs)", detail: "afplay is \(afplay.pid)")
    if let tap = run.system.lastTap {
        r.info("tap", "\(tap.channels) ch at \(Int(tap.sampleRate)) Hz", detail: "aggregate at \(Int(status.sampleRate ?? 0)) Hz")
    }
    r.info("layout", status.layout.map { json($0) } ?? "none")

    let recorder = try Recorder(device: duette, seconds: 30)
    run.overloads.watch(duette, name: "Duette (this reader)")
    Stage.set("recording Duette")
    try recorder.start()
    defer { recorder.stop() }
    recorder.waitForFrames(4800, timeout: 5)
    let mix = recorder.cleanTake(seconds: 2, settle: 0.5, overloads: run.overloads)

    if expectDenied {
        // With System Audio Recording denied, the tap is expected to give exact silence, and the
        // controller to say so after EngineController.silenceHintSeconds.
        r.tones("denied", mix, expect: [.absent(toneHz, below: absentDBFS), .at(testMicHz, dbfsMinus12)], damaged: !WindowLog.lastClean)
        let denied = run.engine.stats()
        let frames = Double(denied.tapZeroFrames) / Device.sampleRate
        r.check("denied.tap-zeros", !denied.tapHadAudio && frames > 2, String(format: "%.1f s of exact zeros", frames),
                detail: "the engine's count of exact-zero tap frames since it started; tap had audio \(denied.tapHadAudio)")
        let hinted = waitUntil(EngineController.silenceHintSeconds + 3) { run.controller.status.appSilentWhilePlaying }
        r.check("denied.hint", hinted, "appSilentWhilePlaying \(run.controller.status.appSilentWhilePlaying)",
                detail: "tap zero run \(run.engine.stats().tapZeroFrames) frames, tap had audio \(run.engine.stats().tapHadAudio)")
        // The controller asks macOS (the private TCC preflight) before it trusts silence from a tap.
        // This process was denied in TCC.db, so the real answer must be "denied", and it must
        // reach the controller through PIDAudioSystem.
        let preflight = run.system.systemAudioCaptureAuthorization()
        r.check("denied.preflight", preflight == .denied, "\(preflight), raw answer \(run.system.systemAudioCaptureRawAnswer().map { String($0) } ?? "none")",
                detail: "TCCAccessPreflight(kTCCServiceAudioCapture) for this process after the denial in TCC.db")
        r.engineStats(run)
        return
    }

    r.tones("mix", mix, expect: [.at(toneHz, dbfsMinus12), .at(testMicHz, dbfsMinus12)])
    r.tones("mix.right", recorder.cleanTake(seconds: 1, overloads: run.overloads, channel: 1), expect: [.at(toneHz, dbfsMinus12), .at(testMicHz, dbfsMinus12)])
    let stats = run.engine.stats()
    r.check("tap.audio", stats.tapHadAudio, "tap had audio \(stats.tapHadAudio)",
            detail: "tap zero run \(stats.tapZeroFrames) frames; zeros only would mean capture permission is denied")
    r.info("preflight", "\(run.system.systemAudioCaptureAuthorization()), raw answer \(run.system.systemAudioCaptureRawAnswer().map { String($0) } ?? "none")",
           detail: "TCCAccessPreflight(kTCCServiceAudioCapture) for this process while System Audio Recording is allowed in TCC.db")
    r.dropouts("mix.dropouts", mix)
    r.residual("residual", mix, tones: [toneHz, testMicHz])
    let meters = run.engine.meters()
    r.meter("app", meters.app, dbfs: dbfsMinus12)
    r.meter("mic", meters.mic, dbfs: dbfsMinus12)

    run.engine.setGain(0.5, for: .app)
    r.tones("app-gain-0.5", recorder.cleanTake(seconds: 1, overloads: run.overloads),
            expect: [.at(toneHz, dbfsMinus12 - 6.0206), .at(testMicHz, dbfsMinus12)])
    run.engine.setMuted(true, for: .mic)
    r.tones("mic-muted", recorder.cleanTake(seconds: 1, overloads: run.overloads),
            expect: [.at(toneHz, dbfsMinus12 - 6.0206), .absent(testMicHz, below: absentDBFS)], damaged: !WindowLog.lastClean)
    run.engine.setMuted(false, for: .mic)
    run.engine.setMuted(true, for: .app)
    r.tones("app-muted", recorder.cleanTake(seconds: 1, overloads: run.overloads),
            expect: [.absent(toneHz, below: absentDBFS), .at(testMicHz, dbfsMinus12)], damaged: !WindowLog.lastClean)
    // Both muted: exact zeros, so neither mute lets anything through. A late cycle only adds
    // zeros, so this holds on any machine.
    run.engine.setMuted(true, for: .mic)
    let both = recorder.take(seconds: 1, settle: 0.2)
    let bothStats = SignalStats(both)
    r.check("both-muted.silence", !both.isEmpty && bothStats.peak == 0, String(format: "peak %.6f", bothStats.peak),
            detail: "app and mic muted: \(both.count) frames of exact zeros")
    run.engine.setMuted(false, for: .mic)
    run.engine.setMuted(false, for: .app)
    run.engine.setGain(1, for: .app)
    r.check("no-silence-hint", !run.controller.status.appSilentWhilePlaying, "appSilentWhilePlaying \(run.controller.status.appSilentWhilePlaying)")
    r.engineStats(run)
}
