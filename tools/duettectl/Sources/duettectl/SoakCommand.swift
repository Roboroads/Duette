import AppKit
import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

// MARK: - soak

let duetteAppBundleID = "me.roboroads.duette"

/// The engine for a while, second by second (see SoakPlan for the two kinds). For each buffer
/// size: dropouts, late I/O cycles (per minute), the mic's drift against the sink, and at the end
/// "Measure latency". One SOAK line sums it up; `--out` writes everything to a file to attach.
func runSoak(_ ctx: Context) throws {
    let r = ctx.reporter
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        ?? NSHomeDirectory() + "/Desktop"
    let plan = try SoakPlan(ctx.invocation, defaultBuffer: ctx.buffer, desktop: desktop, now: Date())
    var notes: [String] = []
    let started = Date()

    // The file first, so a soak that cannot write its result says so now and not after 20 minutes.
    let outPath = plan.outPath.flatMap { prepareResultFile($0, started: started) }
    if plan.real {
        let minutes = Int((plan.minutes * Double(plan.buffers.count) + plan.controlSeconds / 60 + 1).rounded(.up))
        print("Keep sound going near the microphone the whole time: play music near the Mac, or keep talking. "
            + "This takes about \(minutes) minutes.")
    }

    do {
        try soak(ctx, plan, notes: &notes)
    } catch {
        r.record("error", .fail, "\(error)", detail: "at: \(Stage.value)")
    }

    var written: String?
    if let path = outPath {
        let text = plan.report(header: soakHeader(plan, started: started), checks: r.checks, notes: notes)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            written = path
        } catch {
            r.record("out", .fail, "could not write \(path)", detail: "\(error)")
        }
    }
    // The verdict last, once the file holds it too.
    print(plan.verdict(r.checks))
    if let written { print("Send this file: \(written)") }
    let status = plan.exitStatus(r.checks)
    if status == 2 {
        fflush(stdout)
        exit(2)
    }
}

/// Creates the result file (or one of the same name in the current folder if that fails) and
/// returns where it is, or nil if neither can be written.
private func prepareResultFile(_ path: String, started: Date) -> String? {
    let placeholder = "Duette soak started \(ISO8601DateFormatter().string(from: started)); "
        + "if this is all there is, it did not finish.\n"
    func tryWrite(_ path: String) -> Bool {
        (try? placeholder.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
    if tryWrite(path) { return path }
    let fallback = FileManager.default.currentDirectoryPath + "/" + URL(fileURLWithPath: path).lastPathComponent
    if fallback != path, tryWrite(fallback) {
        print("Cannot write \(path); the result goes to \(fallback) instead.")
        return fallback
    }
    print("Cannot write \(path) or \(fallback): the result is only shown here.")
    return nil
}

private func soak(_ ctx: Context, _ plan: SoakPlan, notes: inout [String]) throws {
    let r = ctx.reporter
    note("soak: \(plan.real ? "real" : "CI test devices"), mic \(plan.mic), app \(plan.app ?? "none"), "
        + "\(plan.buffers.map { String($0) }.joined(separator: ", ")) frames, \(plan.minutes) min each")
    // The app's engine would write to the sink too, and the two would cut each other up.
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: duetteAppBundleID)
    if !apps.isEmpty {
        r.check("duette-app-quit", false, "the Duette app is running",
                detail: "quit it first (Duette in the menu bar > Quit Duette), then run this again")
        return
    }
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    if !plan.real {
        guard Device.find(uid: DuetteDriver.testMicUID, timeout: 10) != nil,
              Device.find(uid: DuetteDriver.testSpeakerUID, timeout: 10) != nil else {
            r.skip("test-devices", "not found",
                   detail: "needs the driver built with DUETTE_TEST_DEVICES=ON; on a Mac with the installed driver use --hands-on")
            return
        }
    }
    try? HAL.setDriverSelfTestTone(false)

    if plan.controlSeconds > 0, let buffer = plan.buffers.first {
        notes += controlRun(r, seconds: plan.controlSeconds, buffer: buffer)
    }
    for buffer in plan.buffers {
        notes += try soakOnce(ctx, plan, buffer: buffer, duette: duette)
    }
}

/// Late cycles on the default output with an IOProc that plays silence: what this Mac does
/// without Duette.
private func controlRun(_ r: Reporter, seconds: Double, buffer: UInt32) -> [String] {
    guard let output = Device.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
        r.skip("control.default-output", "no default output")
        return []
    }
    let name = Device.name(output)
    let log = OverloadLog()
    log.watch(output, name: name)
    try? Device.setBufferFrameSize(output, buffer)
    Stage.set("control: silence into '\(name)' for \(Int(seconds)) s")
    do {
        let player = try Player(device: output, signal: [], sampleRate: Device.nominalRate(output) ?? Device.sampleRate)
        try player.start()
        player.arm()
        idle(seconds)
        player.stop()
    } catch {
        r.skip("control.default-output", "\(error)")
        return []
    }
    let count = log.count(output)
    r.info("control.default-output", "\(count) in \(Int(seconds)) s",
           detail: String(format: "'%@' at %u frames, an IOProc that plays silence: late cycles this Mac has without Duette (%.1f per minute)",
                          name, buffer, Double(count) / seconds * 60))
    return ["control: \(count) late cycles in \(Int(seconds)) s on '\(name)'"]
}

/// The longest run of exact zeros (both channels) the mic itself delivered over the 1.1 s that
/// went into the "Duette" second just read. `duetteBehind`: frames "Duette" has recorded past the
/// end of that second. Nil if the mic's recording no longer holds that time.
private func micZeroRun(_ mic: Recorder, duetteBehind: UInt64) -> Int? {
    let rate = mic.sampleRate
    let span = Int(1.1 * rate)
    let behind = Double(duetteBehind) * rate / Device.sampleRate
    let end = Double(mic.frames) - behind
    guard end > Double(span), Double(mic.frames) - end + Double(span) < Double(mic.capacity - 1024) else { return nil }
    let stereo = mic.copy(from: UInt64(end) - UInt64(span), count: span)
    guard stereo.count == span * 2 else { return nil }
    var louder = [Float](repeating: 0, count: span)
    for i in 0..<span { louder[i] = max(abs(stereo[2 * i]), abs(stereo[2 * i + 1])) }
    return SignalStats(louder).longestZeroRun
}

/// Sample time and host time of a running device now.
private func clockReading(_ device: AudioObjectID) -> ClockReading? {
    var stamp = AudioTimeStamp()
    stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
    guard AudioDeviceGetCurrentTime(device, &stamp) == 0 else { return nil }
    return ClockReading(sampleTime: stamp.mSampleTime, nanos: Double(AudioConvertHostTimeToNanos(stamp.mHostTime)))
}

private func soakOnce(_ ctx: Context, _ plan: SoakPlan, buffer: UInt32, duette: AudioObjectID) throws -> [String] {
    let r = ctx.reporter
    let prefix = plan.checkPrefix(for: buffer)
    var notes: [String] = []

    // CI with --with-app: another duettectl plays 440 Hz into the test speaker for the whole run.
    var player: Process?
    var playerCleanup: Int?
    defer {
        if let player, player.isRunning {
            player.terminate()
            player.waitUntilExit()
        }
        if let playerCleanup { Cleanup.remove(playerCleanup) }
    }
    var app = plan.app
    if plan.withApp, let speaker = Device.find(uid: DuetteDriver.testSpeakerUID) {
        try Device.setNominalRate(speaker, 48000)
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["play", "--device", DuetteDriver.testSpeakerUID, "--hz", "440", "--dbfs", "-12",
                             "--seconds", String(Int(plan.minutes * 60 + 60)), "--timeout", "0"]
        try process.run()
        playerCleanup = Cleanup.add(process)
        player = process
        waitUntil(10, interval: 0.1) {
            HAL.processObjectID(forPID: process.processIdentifier).flatMap(HAL.processInfo)?.isRunningOutput ?? false
        }
        app = PIDAudioSystem.bundleID(pid: process.processIdentifier)
    }

    let run = EngineRun()
    run.start(app: app, mic: plan.mic, buffer: buffer)
    defer { run.stop() }

    // The engine runs with whatever of the mic and the app is there.
    Stage.set("waiting for the engine to run at \(buffer) frames")
    var status: EngineStatus?
    waitUntil(30, interval: 0.05) {
        let now = run.controller.status
        if case .running = now.state { status = now }
        if case .waitingForApp = now.state { status = now }
        return status != nil
    }
    let now = run.controller.status
    if case .waitingForApp(let bundleID) = now.state {
        r.check(prefix + "state", false, "\(bundleID) is not running",
                detail: "start it (and let it play), or leave out --app")
        return notes
    }
    guard let status, case .running(let sources) = status.state else {
        r.check(prefix + "state", false, describe(now.state), detail: "last error \(now.lastError.map { "\($0)" } ?? "none")")
        return notes
    }
    let wantApp = app != nil
    let wantMic = plan.real ? status.micUID != nil : true
    r.check(prefix + "state", sources == EngineSources(mic: wantMic, app: wantApp), describe(status.state),
            detail: "mic \(status.micName ?? "none"), app \(app ?? "none"); last error \(now.lastError.map { "\($0)" } ?? "none")")
    if let aggregate = status.aggregateID { run.overloads.watch(aggregate, name: "the engine's aggregate") }
    run.overloads.watch(duette, name: "Duette (this reader)")
    reportTiming(r, aggregate: status.aggregateID, duette: duette, prefix: prefix)

    let recorder = try Recorder(device: duette, seconds: 10)
    try recorder.start()
    defer { recorder.stop() }
    recorder.waitForFrames(48000, timeout: 5)

    // Something must come through at all. Only silence means this process may not record, or
    // (with a real mic) that the room is quiet: then nothing can be tested.
    var first = recorder.take(seconds: 1, settle: 0.2)
    if plan.real {
        let deadline = Date().addingTimeInterval(15)
        while SignalStats(first).peak == 0, Date() < deadline { first = recorder.take(seconds: 1, settle: 0) }
    }
    let peak = SignalStats(first).peak
    let silenceHelp = "only silence from Duette: if macOS asked whether Terminal may use the microphone, allow it "
        + "(System Settings > Privacy & Security > Microphone)"
    if peak > 0 {
        r.check(prefix + "signal", true, String(format: "peak %.4f", peak), detail: "sound from Duette")
    } else if plan.real {
        r.skip(prefix + "signal", "only silence for 15 s", detail: silenceHelp)
        return notes
    } else {
        r.check(prefix + "signal", false, "peak 0", detail: silenceHelp)
        return notes
    }

    // The clocks of "Duette" (it shares the sink's) and the mic, for the drift between them. A
    // device's current time can be read only while this process runs IO on it itself, so a small
    // recorder runs on the mic as well.
    let micID = status.micUID.flatMap { Device.find(uid: $0) }
    var micClock: Recorder?
    if let micID, let clock = try? Recorder(device: micID, seconds: 4, sampleRate: Device.nominalRate(micID) ?? Device.sampleRate) {
        do {
            try clock.start()
            clock.waitForFrames(4800, timeout: 3)
            micClock = clock
        } catch {
            note("drift: cannot run IO on the mic to read its clock: \(error)")
        }
    }
    defer { micClock?.stop() }
    let sinkStart = clockReading(duette)
    let micStart = micClock != nil ? micID.flatMap(clockReading) : nil

    let window = 48000
    var expect: [ToneExpectation] = []
    if !plan.real {
        expect = [.at(testMicHz, dbfsMinus12)]
        if plan.withApp { expect.append(.at(toneHz, dbfsMinus12)) }
    }
    var cursor = recorder.frames
    let soakStart = Date()
    let total = plan.minutes * 60
    var windows = 0, failedWindows = 0, silentWindows = 0, micZeroWindows = 0, soundWindows = 0
    var unexplained = 0, longestZeroRun = 0
    var worstDB = 0.0, worstHz = 0.0
    var firstFailure: String?
    var failed: [(end: Date, what: String)] = []
    Stage.set("soaking at \(buffer) frames for \(plan.minutes) minutes")
    while Date().timeIntervalSince(soakStart) < total {
        guard recorder.waitForFrames(cursor + UInt64(window), timeout: 5) else {
            failedWindows += 1
            let what = "no audio from Duette for 5 s at \(Int(Date().timeIntervalSince(soakStart))) s"
            firstFailure = firstFailure ?? what
            failed.append((Date().addingTimeInterval(-4), what))
            cursor = recorder.frames
            continue
        }
        let samples = recorder.channel(0, from: cursor, count: window)
        cursor += UInt64(window)
        windows += 1
        let stats = SignalStats(samples)
        let at = Int(Date().timeIntervalSince(soakStart))
        var bad: String?
        if plan.real {
            if SoakPlan.hasSound(zeros: stats.zeros, frames: samples.count) { soundWindows += 1 }
            let micRun = stats.longestZeroRun >= SoakPlan.dropoutFrames
                ? micClock.flatMap { micZeroRun($0, duetteBehind: recorder.frames - cursor) } : nil
            switch SoakPlan.classify(peak: stats.peak, longestZeroRun: stats.longestZeroRun, micLongestZeroRun: micRun) {
            case .sound:
                longestZeroRun = max(longestZeroRun, stats.longestZeroRun)
            case .silent:
                silentWindows += 1
            case .micZeros:
                micZeroWindows += 1
            case .dropout:
                longestZeroRun = max(longestZeroRun, stats.longestZeroRun)
                bad = String(format: "window %ld at %ld s: %ld frames of exact zeros in a second with sound, starting %.3f s in",
                             windows, at, stats.longestZeroRun, Double(stats.longestZeroRunStart) / Device.sampleRate)
            }
            if samples.count < window { bad = bad ?? "window \(windows) at \(at) s: only \(samples.count) frames" }
        } else {
            let results = ToneChecker.check(samples, sampleRate: Device.sampleRate, expect: expect)
            longestZeroRun = max(longestZeroRun, stats.longestZeroRun)
            for result in results {
                if let measured = result.measured, case .dbfs(let want) = result.expectation.level {
                    worstDB = max(worstDB, abs(measured.dbfs - want))
                    worstHz = max(worstHz, abs(measured.frequency - result.expectation.frequency))
                }
            }
            if results.contains(where: { !$0.passed }) || samples.count < window || stats.longestZeroRun >= SoakPlan.dropoutFrames {
                bad = "window \(windows) at \(at) s: " + results.map(\.description).joined(separator: "; ")
                    + ", zero run \(stats.longestZeroRun)"
            }
        }
        if let bad {
            failedWindows += 1
            firstFailure = firstFailure ?? bad
            failed.append((Date(), bad))
        }
        if windows % 60 == 0 {
            note("soak \(buffer): \(windows) s, \(failedWindows) failed seconds, \(run.engine.stats().overloads) engine overloads, "
                + "\(run.overloads.count(duette)) reader overloads")
        }
    }
    let elapsed = Date().timeIntervalSince(soakStart)
    let sinkEnd = clockReading(duette)
    let micEnd = micClock != nil ? micID.flatMap(clockReading) : nil
    micClock?.stop()

    r.info(prefix + "duration", String(format: "%.0f s, %ld one-second windows", elapsed, windows))
    let windowDetail: String
    if plan.real {
        windowDetail = "a failed second has sound and a run of \(SoakPlan.dropoutFrames) or more exact zeros (frames that never arrived); "
            + "\(silentWindows) seconds were silent throughout"
    } else {
        windowDetail = String(format: "each window: %@ within 1 dB and 2 Hz; worst %.2f dB, %.2f Hz",
                              expect.map(\.description).joined(separator: ", "), worstDB, worstHz)
    }
    r.check(prefix + "windows", failedWindows == 0 && windows > 0, "\(failedWindows) of \(windows) failed",
            detail: firstFailure ?? windowDetail)
    // A failed second with no overload reported during it (give or take 0.3 s: the notification
    // comes on its own queue) is not the machine's doing.
    let stamps = run.overloads.times
    var firstUnexplained: String?
    for item in failed {
        let from = item.end.addingTimeInterval(-1.3), to = item.end.addingTimeInterval(0.3)
        if !stamps.contains(where: { $0 >= from && $0 <= to }) {
            unexplained += 1
            firstUnexplained = firstUnexplained ?? item.what
        }
    }
    r.check(prefix + "windows.unexplained", unexplained == 0, "\(unexplained) of \(failedWindows) failed windows had no overload",
            detail: firstUnexplained ?? "every failed window coincides with a kAudioDeviceProcessorOverload")
    r.check(prefix + "dropouts", longestZeroRun < SoakPlan.dropoutFrames, "longest zero run \(longestZeroRun) frames",
            detail: plan.real ? "in seconds that had sound" : "anywhere in the recording")
    if plan.real {
        r.info(prefix + "silent-windows", "\(silentWindows) of \(windows)", detail: "seconds of exact silence throughout: nothing came in")
        r.info(prefix + "mic-zeros", "\(micZeroWindows) of \(windows)",
               detail: "seconds whose exact zeros the mic delivered itself (a mute switch, a noise gate): not counted as dropouts")
        let share = windows > 0 ? Double(soundWindows) / Double(windows) : 0
        let value = "\(soundWindows) of \(windows) seconds had sound"
        let detail = String(format: "a second has sound when less than %.0f%% of it is exact zeros; at least %.0f%% of them must, or the gaps could not show",
                            SoakPlan.silentShareLimit * 100, SoakPlan.minimumSoundShare * 100)
        if share >= SoakPlan.minimumSoundShare {
            r.check(prefix + "sound", true, value, detail: detail)
        } else {
            r.skip(prefix + "sound", value, detail: detail)
        }
    }
    let perMinute = SoakPlan.perMinute(stamps.map { $0.timeIntervalSince(soakStart) }, minutes: plan.minutes)
    r.info(prefix + "overloads-per-minute", perMinute.map { String($0) }.joined(separator: " "),
           detail: "kAudioDeviceProcessorOverload on the engine's aggregate and on Duette, minute by minute")
    let readerOverloads = run.overloads.count(duette)
    r.check(prefix + "reader-overloads", readerOverloads == 0, "\(readerOverloads)", detail: "kAudioDeviceProcessorOverload on Duette (this reader)")
    r.engineStats(run, overloadsBlock: true, prefix: prefix)
    r.info(prefix + "rebuilds", "\(run.controller.status.rebuildCount)", detail: "1 means the engine was built once and never torn down")

    // Drift: how far the mic's clock runs from the sink's. The aggregate's drift compensation
    // absorbs it; a large or changing value explains crackles that are not overloads.
    if let sinkStart, let sinkEnd, let micStart, let micEnd,
       let sinkRate = Drift.rate(from: sinkStart, to: sinkEnd), let micRate = Drift.rate(from: micStart, to: micEnd),
       let ppm = Drift.ppm(mic: micRate, sink: sinkRate) {
        r.info(prefix + "drift", String(format: "%+.1f ppm", ppm),
               detail: String(format: "mic '%@' %.3f Hz against the sink's clock (read on Duette) %.3f Hz, from their time stamps over %.0f s",
                              status.micName ?? "?", micRate, sinkRate, elapsed))
    } else {
        r.info(prefix + "drift", "not measured",
               detail: micID == nil ? "no mic in the engine" : micClock == nil ? "no IO on the mic in this process" : "a device's current time was unreadable")
    }

    // Last: "Measure latency", as in the app.
    measureLatencyChecks(r, run, prefix: prefix + "latency.")

    for (minute, count) in perMinute.enumerated() where count > 0 {
        notes.append("\(buffer) frames, minute \(minute + 1): \(count) late cycles")
    }
    let times = stamps.map { String(format: "%.1f", $0.timeIntervalSince(soakStart)) }
    if !times.isEmpty { notes.append("\(buffer) frames, late cycles at (s): " + times.joined(separator: " ")) }
    for item in failed.prefix(20) { notes.append("\(buffer) frames: \(item.what)") }
    return notes
}

/// The top of the result file: when, what Mac, what was soaked.
private func soakHeader(_ plan: SoakPlan, started: Date) -> [String] {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    let input = Device.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).map(Device.name) ?? "none"
    let output = Device.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map(Device.name) ?? "none"
    let driver = Bundle(path: DuetteDriver.bundlePath)?.infoDictionary?["CFBundleShortVersionString"] as? String
    return [
        "Duette soak, \(formatter.string(from: started)) to \(formatter.string(from: Date()))",
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(DiagnosticsCollector.hardwareModel())",
        "driver \(driver ?? "not in \(DuetteDriver.bundlePath)"), duettectl \(CommandLine.arguments.first ?? "?")",
        "default input '\(input)', default output '\(output)'",
        "soak: \(plan.real ? "real mic" : "CI test devices"), mic \(plan.mic), app \(plan.app ?? "none"), "
            + "\(plan.buffers.map { String($0) }.joined(separator: " and ")) frames, \(String(format: "%g", plan.minutes)) min each",
    ]
}
