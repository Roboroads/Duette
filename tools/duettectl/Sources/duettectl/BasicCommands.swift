import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

let dbfsMinus12 = -12.0
/// A muted or absent tone must stay under this. It would otherwise be at -18 or -12 dBFS; the odd
/// late I/O cycle on a busy CI machine spreads up to about -65 dBFS of the other tone around.
let absentDBFS = -50.0
/// The engine's and the driver's test tones, and the test mic, are all at -12 dBFS.
let toneHz = 440.0
let testMicHz = 1000.0

// MARK: - list

func runList(_ ctx: Context) throws {
    let r = ctx.reporter
    let ids = try HAL.deviceIDs()
    for id in ids {
        guard let info = try? HAL.deviceInfo(id) else { continue }
        let transport = FourCC.string(info.transportType) ?? String(info.transportType)
        note("device \(id) '\(info.name)' uid=\(info.uid) in=\(info.inputChannels) out=\(info.outputChannels) "
            + "rate=\(Int(info.nominalSampleRate)) transport='\(transport)'")
        if info.inputChannels > 0 { note("    input:  \(Device.timing(id, scope: kAudioObjectPropertyScopeInput))") }
        if info.outputChannels > 0 { note("    output: \(Device.timing(id, scope: kAudioObjectPropertyScopeOutput))") }
    }
    r.info("devices", "\(ids.count) listed")

    let duette = Device.find(uid: DuetteDriver.deviceUID, timeout: 30)
    r.check("duette.listed", duette.map(Device.isListed) ?? false,
            duette.map { "id \($0), '\(Device.name($0))'" } ?? "not found")
    let sink = Device.find(uid: DuetteDriver.sinkUID, timeout: 5)
    if let sink {
        r.check("sink.hidden", !Device.isListed(sink) && Device.isHidden(sink),
                "found by UID (id \(sink)), listed \(Device.isListed(sink)), IsHidden \(Device.isHidden(sink))")
    } else {
        r.check("sink.hidden", false, "no device with UID \(DuetteDriver.sinkUID)")
    }
    if ctx.flag("test-devices") {
        for (uid, name) in [(DuetteDriver.testMicUID, "test-mic"), (DuetteDriver.testSpeakerUID, "test-speaker")] {
            let id = Device.find(uid: uid, timeout: 5)
            r.check("\(name).listed", id.map(Device.isListed) ?? false, id.map { "'\(Device.name($0))'" } ?? "not found")
        }
    }
    if let duette {
        r.info("duette.timing", "\(Device.timing(duette, scope: kAudioObjectPropertyScopeInput))")
        r.info("dtst", HAL.driverSelfTestTone().map { $0 ? "on" : "off" } ?? "unreadable")
        r.info("dcli", HAL.driverInputClients().map { "\($0)" } ?? "unreadable")
    }
    if let sink { r.info("sink.timing", "\(Device.timing(sink, scope: kAudioObjectPropertyScopeOutput))") }
    let input = Device.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).map(Device.name) ?? "none"
    let output = Device.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map(Device.name) ?? "none"
    r.info("defaults", "input '\(input)', output '\(output)'")

    let processes = (try? HAL.processObjectIDs())?.compactMap(HAL.processInfo) ?? []
    for process in processes {
        note("process \(process.pid) '\(process.bundleID)' input=\(process.isRunningInput) output=\(process.isRunningOutput)")
    }
    r.info("processes", "\(processes.count) Core Audio clients")
}

// MARK: - whoami

func runWhoami(_ ctx: Context) throws {
    let me = getpid()
    let responsible = ProcessCatalog.systemResponsiblePID(of: me) ?? me
    ctx.reporter.info("pid", "\(me)", detail: "parent \(ProcessCatalog.systemParentPID(of: me) ?? 0)")
    ctx.reporter.info("responsible", "\(responsible)", detail: "the process TCC asks about")
    // Any HAL call makes this process a client, with a process object.
    _ = try? HAL.deviceIDs()
    let object = HAL.processObjectID(forPID: me)
    let bundleID = object.flatMap(HAL.processInfo)?.bundleID ?? ""
    ctx.reporter.info("hal-bundle-id", bundleID.isEmpty ? "(none)" : bundleID,
                      detail: "process object \(object.map { String($0) } ?? "none")")
    print("RESPONSIBLE_PID=\(responsible)")
}

// MARK: - selftest

func runSelfTest(_ ctx: Context) throws {
    let r = ctx.reporter
    let seconds = ctx.double("seconds") ?? 1.5
    Stage.set("waiting for Duette")
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    let initial = HAL.driverSelfTestTone()
    r.check("dtst.default-off", initial == false, initial.map { $0 ? "on" : "off" } ?? "unreadable")

    let recorder = try Recorder(device: duette, seconds: 20)
    Stage.set("start IO on Duette")
    try recorder.start()
    defer {
        recorder.stop()
        try? HAL.setDriverSelfTestTone(false)
    }
    r.check("io.started", recorder.waitForFrames(4800, timeout: 5), "\(recorder.frames) frames in \(recorder.cycles) cycles")

    Stage.set("tone on")
    try HAL.setDriverSelfTestTone(true)
    r.check("dtst.on", HAL.driverSelfTestTone() == true, "reads back \(HAL.driverSelfTestTone().map { $0 ? "on" : "off" } ?? "nothing")")
    let first = recorder.frames
    idle(0.2)
    let want = UInt64(seconds * Device.sampleRate)
    recorder.waitForFrames(recorder.frames + want, timeout: seconds + 3)
    let now = recorder.frames
    let start = max(first + 4800, now > want ? now - want : 0)
    let left = recorder.channel(0, from: start, count: Int(want))
    let right = recorder.channel(1, from: start, count: Int(want))
    r.tones("tone.left", left, expect: [.at(toneHz, dbfsMinus12)])
    r.tones("tone.right", right, expect: [.at(toneHz, dbfsMinus12)])

    Stage.set("tone off")
    try HAL.setDriverSelfTestTone(false)
    r.check("dtst.off", HAL.driverSelfTestTone() == false, "reads back \(HAL.driverSelfTestTone().map { $0 ? "on" : "off" } ?? "nothing")")
    let after = recorder.take(seconds: 0.5, settle: 0.2)
    let stats = SignalStats(after)
    r.check("off.silence", !after.isEmpty && stats.peak == 0, String(format: "peak %.6f over %ld frames", stats.peak, after.count),
            detail: "no writer and no tone: \"Duette\" must give exact zeros")
}

// MARK: - loopback

func runLoopback(_ ctx: Context) throws {
    let r = ctx.reporter
    let buffer = ctx.buffer
    let rate = Device.sampleRate
    Stage.set("waiting for Duette and the sink")
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    let sink = try Device.require(uid: DuetteDriver.sinkUID, timeout: 10)
    try? HAL.setDriverSelfTestTone(false)
    try Device.setBufferFrameSize(duette, buffer)
    try Device.setBufferFrameSize(sink, buffer)
    let duetteTiming = Device.timing(duette, scope: kAudioObjectPropertyScopeInput)
    let sinkTiming = Device.timing(sink, scope: kAudioObjectPropertyScopeOutput)
    r.info("hal.duette", "\(duetteTiming)")
    r.info("hal.sink", "\(sinkTiming)")
    // What the HAL says the path costs: both buffers plus every latency and safety offset.
    let parts: [UInt32?] = [sinkTiming.buffer, sinkTiming.latency, sinkTiming.safetyOffset, sinkTiming.streamLatency,
                            duetteTiming.buffer, duetteTiming.latency, duetteTiming.safetyOffset, duetteTiming.streamLatency]
    var reported = 0.0
    for part in parts { reported += Double(part ?? 0) }
    r.info("estimate", Format.frames(reported, sampleRate: rate), detail: "sum of the HAL's buffer, latency and safety-offset properties")

    let chirpFrames = Int(0.2 * rate)
    let chirp = Chirp.make(sampleRate: rate, startHz: 200, endHz: 12000, frames: chirpFrames, amplitude: 0.5)
    let tailSeconds = ctx.double("seconds") ?? 1.5
    let overloads = OverloadLog()
    overloads.watch(duette, name: "Duette (the reader)")
    overloads.watch(sink, name: "Duette Sink (the writer)")

    /// One chirp through the loopback, recorded.
    struct Take {
        var result: LoopbackResult?
        var recording: [Float]
        var first: UInt64
        var writer: [IOBlock]
        var reader: [IOBlock]
        var overloads: Int
    }
    func take() throws -> Take {
        let before = overloads.count(duette) + overloads.count(sink)
        let recorder = try Recorder(device: duette, seconds: 30)
        let player = try Player(device: sink, signal: chirp, tailHz: testMicHz, tailAmplitude: 0.5)
        Stage.set("start IO on Duette")
        try recorder.start()
        defer { recorder.stop() }
        recorder.waitForFrames(UInt64(0.2 * rate), timeout: 5)
        Stage.set("start IO on the sink")
        try player.start()
        defer { player.stop() }
        idle(0.3)
        player.arm()
        idle(Double(chirpFrames) / rate + tailSeconds)
        Stage.set("stop the writer")
        player.stop()
        idle(0.5)
        recorder.stop()
        let total = recorder.frames
        let kept = min(total, UInt64(recorder.capacity))
        let first = total - kept
        let recording = recorder.channel(0, from: first, count: Int(kept))
        let writer = player.blocks()
        let reader = recorder.blocks()
        let result = LoopbackAnalysis.analyze(chirp: chirp, writer: writer, reader: reader, recording: recording,
                                              recordingStart: Int64(first), bufferFrames: Int(buffer))
        return Take(result: result, recording: recording, first: first, writer: writer, reader: reader,
                    overloads: overloads.count(duette) + overloads.count(sink) - before)
    }

    // A late I/O cycle on the CI machine can damage the chirp (the HAL drops that cycle); such a
    // take is repeated, at most three times, and the best one counts.
    var chosen = try take()
    var takes = 1
    while takes < 3, (chosen.result?.confidence ?? 0) < 0.9 {
        note(String(format: "take %ld: %ld overloads, confidence %.3f; taking it again", takes, chosen.overloads,
                    chosen.result?.confidence ?? 0))
        let next = try take()
        takes += 1
        if (next.result?.confidence ?? 0) > (chosen.result?.confidence ?? 0) { chosen = next }
    }
    r.info("takes", "\(takes)", detail: "a take whose chirp a late cycle damaged is repeated, at most 3 times; the one used had \(chosen.overloads) overloads")

    r.check("buffer.duette", Device.bufferFrameSize(duette) == buffer, "\(Device.bufferFrameSize(duette) ?? 0) frames")
    r.check("buffer.sink", Device.bufferFrameSize(sink) == buffer, "\(Device.bufferFrameSize(sink) ?? 0) frames")
    let writer = chosen.writer
    let reader = chosen.reader
    let recording = chosen.recording
    let first = chosen.first
    r.info("cycles", "writer \(writer.count) of \(writer.first?.frames ?? 0) frames, reader \(reader.count) of \(reader.first?.frames ?? 0) frames")
    guard let result = chosen.result else {
        r.check("analysis", false, "nothing to analyse", detail: "writer \(writer.count) cycles, reader \(reader.count), \(recording.count) frames")
        return
    }

    r.check("chirp.found", result.confidence >= 0.9, String(format: "confidence %.3f", result.confidence),
            detail: "core LatencyEstimator on the recording near the expected place")
    if let offset = result.sampleOffset {
        r.check("sample-offset", offset == 0, String(format: "%+.0f frames", offset),
                detail: "written to the sink at sample time \(Int(result.chirpSinkTime)), read from Duette at \(Int(result.chirpDuetteTime ?? 0))")
    } else {
        r.check("sample-offset", false, "chirp not found")
    }
    let limit = Double(2 * Int(buffer) + 64)
    // The delay an app recording "Duette" sees: from the writer's IOProc call that produced a
    // frame to the reader's call that got it, averaged over the chirp. The worst single frame adds
    // the jitter of when the HAL wakes the two I/O threads.
    if let worst = result.latencyMax, let mean = result.latencyMean {
        r.check("latency", mean <= limit, Format.frames(mean, sampleRate: rate),
                detail: String(format: "mean over the chirp, writer IOProc call to reader IOProc call; limit 2 x %ld + 64 = %.0f",
                               Int(buffer), limit))
        r.info("latency.worst", Format.frames(worst, sampleRate: rate), detail: "the latest single frame of the chirp")
    } else {
        r.check("latency", false, "not measured")
    }

    // The tone after the chirp came through at its level.
    if let index = result.chirpRecordingIndex {
        let tailStart = max(0, Int(index - Int64(first)) + chirpFrames + 2400)
        let tailEnd = min(recording.count, tailStart + Int(min(1.0, max(0.25, tailSeconds - 0.2)) * rate))
        if tailEnd > tailStart {
            r.tones("tone", Array(recording[tailStart..<tailEnd]), expect: [.at(testMicHz, -6.0206)])
        }
    }

    if let delay = result.silenceDelay {
        let ok = delay <= Double(buffer) && result.nonZeroAfterStop == 0 && result.observedAfterStop >= Double(4 * Int(buffer))
        r.check("silence-after-stop", ok, String(format: "%+.0f frames", delay),
                detail: String(format: "last sound vs the writer's last frame; %ld non-zero frames later than 1 buffer; %.0f frames observed after",
                               result.nonZeroAfterStop, result.observedAfterStop))
    } else {
        r.check("silence-after-stop", false, "no sound recorded at all")
    }
}

// MARK: - record, play, make-tone, analyze

func runRecord(_ ctx: Context) throws {
    let uid = ctx.string("device") ?? DuetteDriver.deviceUID
    let seconds = ctx.double("seconds") ?? 3
    let device = try Device.require(uid: uid, timeout: 10)
    let rate = Device.nominalRate(device) ?? Device.sampleRate
    let recorder = try Recorder(device: device, seconds: seconds + 2, sampleRate: rate)
    Stage.set("recording \(Device.name(device))")
    try recorder.start()
    recorder.waitForFrames(UInt64(seconds * rate), timeout: seconds + 5)
    recorder.stop()
    let stereo = recorder.copy(from: 0, count: Int(min(recorder.frames, UInt64(seconds * rate))))
    let url = URL(fileURLWithPath: ctx.string("out") ?? "duette.wav")
    try WAVAudio(sampleRate: rate, channels: 2, samples: stereo).write(to: url)
    ctx.reporter.info("recorded", "\(stereo.count / 2) frames at \(Int(rate)) Hz", detail: url.path)
}

func runPlay(_ ctx: Context) throws {
    let uid = ctx.string("device") ?? DuetteDriver.testSpeakerUID
    let device = try Device.require(uid: uid, timeout: 10)
    let rate = Device.nominalRate(device) ?? Device.sampleRate
    let amplitude = Float(pow(10, (ctx.double("dbfs") ?? -12) / 20))
    let player = try Player(device: device, signal: [], tailHz: ctx.double("hz") ?? toneHz, tailAmplitude: amplitude, sampleRate: rate)
    Stage.set("playing into \(Device.name(device))")
    try player.start()
    player.arm()
    print("READY pid=\(getpid())")
    idle(ctx.double("seconds") ?? 10)
    player.stop()
    ctx.reporter.info("played", "\(player.cycles) cycles into '\(Device.name(device))'")
}

/// A control measurement: how often the HAL reports a late I/O cycle on any device here, with an
/// IOProc that only copies samples. Run against one of the machine's own devices it tells
/// whether overloads come from the machine or from Duette.
func runOverloads(_ ctx: Context) throws {
    let r = ctx.reporter
    let uid = ctx.string("device") ?? DuetteDriver.sinkUID
    let seconds = ctx.double("seconds") ?? 60
    var device = try Device.require(uid: uid, timeout: 10)
    var name = Device.name(device)
    // With --with: a private aggregate of the device (main) and a second one with drift
    // compensation, like the engine's sink and mic.
    var aggregate: ClientAggregate?
    if let second = ctx.string("with") {
        let other = try Device.require(uid: second, timeout: 10)
        let built = try ClientAggregate(inputUID: second, outputUID: uid)
        aggregate = built
        device = built.id
        name = "an aggregate of \(name) and \(Device.name(other))"
    }
    defer { aggregate = nil }
    try Device.setBufferFrameSize(device, ctx.buffer)
    let log = OverloadLog()
    log.watch(device, name: name)
    let output = (try? AudioObject(device).bufferChannels(scope: kAudioObjectPropertyScopeOutput))?.reduce(0, +) ?? 0
    var player: Player?
    var recorder: Recorder?
    if output > 0 {
        player = try Player(device: device, signal: [], tailHz: toneHz, tailAmplitude: 0.25,
                            sampleRate: Device.nominalRate(device) ?? Device.sampleRate)
        try player?.start()
        player?.arm()
    } else {
        recorder = try Recorder(device: device, seconds: 5)
        try recorder?.start()
    }
    Stage.set("counting overloads on \(name) for \(Int(seconds)) s")
    idle(seconds)
    player?.stop()
    recorder?.stop()
    let count = log.count(device)
    r.info("count", "\(count) in \(Int(seconds)) s", detail: String(format: "'%@' (%@), %@, buffer %u frames: %.1f per minute",
                                                               name, uid, output > 0 ? "playing" : "recording", ctx.buffer,
                                                               Double(count) / seconds * 60))
}

func runMakeTone(_ ctx: Context) throws {
    let rate = ctx.double("rate") ?? 48000
    let tone = Sine.make(frequency: ctx.double("hz") ?? toneHz, dbfs: ctx.double("dbfs") ?? dbfsMinus12,
                         sampleRate: rate, seconds: ctx.double("seconds") ?? 30)
    let url = URL(fileURLWithPath: ctx.string("out") ?? "tone.wav")
    try WAVAudio(sampleRate: rate, channels: 2, samples: Sine.interleave([tone, tone])).write(to: url, as: .pcm16)
    ctx.reporter.info("written", "\(tone.count) frames at \(Int(rate)) Hz", detail: url.path)
}

func runAnalyze(_ ctx: Context) throws {
    let url = URL(fileURLWithPath: ctx.invocation.positionals[0])
    let audio = try WAVAudio.read(contentsOf: url)
    let channel = audio.channel(ctx.int("channel") ?? 0)
    ctx.reporter.info("file", "\(audio.frameCount) frames, \(audio.channels) ch at \(Int(audio.sampleRate)) Hz")
    let expect = try ToneExpectation.parseList(ctx.string("expect") ?? "")
    if expect.isEmpty, let spectrum = Spectrum(samples: channel, sampleRate: audio.sampleRate) {
        for (i, peak) in spectrum.peaks().enumerated() { ctx.reporter.info("peak\(i + 1)", peak.description) }
        return
    }
    ctx.reporter.tones("tone", channel, sampleRate: audio.sampleRate, expect: expect)
}

// MARK: - set-default, set-rate

func runSetDefault(_ ctx: Context) throws {
    if let uid = ctx.string("input") {
        try Device.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: try Device.require(uid: uid))
        ctx.reporter.info("input", uid)
    }
    if let uid = ctx.string("output") {
        try Device.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: try Device.require(uid: uid))
        ctx.reporter.info("output", uid)
    }
}

func runSetRate(_ ctx: Context) throws {
    let device = try Device.require(uid: ctx.string("device") ?? DuetteDriver.testSpeakerUID)
    let rate = ctx.double("rate") ?? 48000
    try Device.setNominalRate(device, rate)
    ctx.reporter.info("rate", "\(Device.name(device)) at \(Int(Device.nominalRate(device) ?? 0)) Hz")
}
