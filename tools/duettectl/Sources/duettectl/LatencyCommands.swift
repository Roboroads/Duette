import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

// MARK: - latency

/// "Measure latency" as the app runs it: EngineController pauses the engine, a chirp goes
/// through the sink into "Duette", and the engine starts again on the same aggregate. The measured
/// loopback must match the estimate the app shows to within LatencyModel.toleranceMilliseconds.
func runLatency(_ ctx: Context) throws {
    let r = ctx.reporter
    let mic = MicArgument(ctx.string("mic") ?? "test-mic")
    let duette = try Device.require(uid: DuetteDriver.deviceUID, timeout: 30)
    if mic == .testMic, Device.find(uid: DuetteDriver.testMicUID, timeout: 10) == nil {
        r.skip("test-mic", "not found", detail: "needs the driver built with DUETTE_TEST_DEVICES=ON; on a Mac use --mic default")
        return
    }
    try? HAL.setDriverSelfTestTone(false)

    let run = EngineRun()
    run.start(app: nil, mic: mic, buffer: ctx.buffer)
    defer { run.stop() }
    guard let status = r.engineRunning(run, EngineSources(mic: mic != .none, app: false)) else { return }
    reportTiming(r, aggregate: status.aggregateID, duette: duette)

    guard measureLatencyChecks(r, run, prefix: "") != nil else { return }

    if mic == .testMic {
        // The mix is back: the test mic's tone reaches "Duette" again.
        let recorder = try Recorder(device: duette, seconds: 5)
        run.overloads.watch(duette, name: "Duette (this reader)")
        try recorder.start()
        defer { recorder.stop() }
        recorder.waitForFrames(4800, timeout: 5)
        r.tones("after", recorder.cleanTake(seconds: 1, settle: 0.3, overloads: run.overloads),
                expect: [.at(testMicHz, dbfsMinus12)])
    }
    r.engineStats(run)
}

/// The HAL's figures the estimate is made of.
func reportTiming(_ r: Reporter, aggregate: AudioObjectID?, duette: AudioObjectID, prefix: String = "") {
    if let aggregate {
        r.info(prefix + "hal.aggregate", "input \(Device.timing(aggregate, scope: kAudioObjectPropertyScopeInput))",
               detail: "output \(Device.timing(aggregate, scope: kAudioObjectPropertyScopeOutput))")
    }
    if let sink = Device.find(uid: DuetteDriver.sinkUID) {
        r.info(prefix + "hal.sink", "\(Device.timing(sink, scope: kAudioObjectPropertyScopeOutput))")
    }
    r.info(prefix + "hal.duette", "\(Device.timing(duette, scope: kAudioObjectPropertyScopeInput))",
           detail: "the buffer is this process's own setting; the estimate takes a reader at the engine's")
}

/// Runs EngineController.measureLatency on a running engine and checks what it found: the chirp
/// came back at the sample time it was written, the loopback matches the estimate, and the engine
/// runs again afterwards without a rebuild.
@discardableResult
func measureLatencyChecks(_ r: Reporter, _ run: EngineRun, prefix: String) -> LatencyMeasurement? {
    let before = run.controller.status
    Stage.set("measuring the latency (the engine pauses for about a second)")
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<LatencyMeasurement, LatencyMeasurementError>?
    run.controller.measureLatency { result in
        outcome = result
        done.signal()
    }
    guard done.wait(timeout: .now() + 30) == .success, let outcome else {
        r.check(prefix + "measured", false, "no result in 30 s", detail: "EngineController.measureLatency")
        return nil
    }
    let measurement: LatencyMeasurement
    switch outcome {
    case .failure(let error):
        r.check(prefix + "measured", false, "\(error)", detail: "EngineController.measureLatency")
        return nil
    case .success(let value):
        measurement = value
    }

    let loopback = measurement.loopback
    let rate = measurement.sampleRate
    r.check(prefix + "measured", loopback.confidence >= 0.9, Format.frames(loopback.meanFrames, sampleRate: rate),
            detail: String(format: "loopback at %u frames, mean writer IOProc call to reader IOProc call over the chirp; worst %.0f frames; confidence %.3f; %ld take(s)",
                           loopback.bufferFrameSize, loopback.worstFrames, loopback.confidence, loopback.takes))
    r.check(prefix + "sample-offset", loopback.sampleOffset == 0, String(format: "%+.0f frames", loopback.sampleOffset),
            detail: "where the chirp landed in Duette relative to where it was written")
    r.check(prefix + "matches-estimate", measurement.matchesEstimate, String(format: "%+.2f ms", measurement.differenceMilliseconds),
            detail: String(format: "measured %@, the app's estimate %@; limit %.0f ms either way",
                           Format.frames(loopback.meanFrames, sampleRate: rate),
                           Format.frames(Double(measurement.estimate.loopbackFrames), sampleRate: rate),
                           LatencyModel.toleranceMilliseconds))
    r.info(prefix + "total", String(format: "Duette adds about %.0f ms; microphone to other apps about %.0f ms",
                                    measurement.addedMilliseconds, measurement.totalMilliseconds),
           detail: String(format: "Duette's part is the %.0f frames measured; with the HAL's %u for the mic into the engine, %.0f frames. Estimate %u frames (%.2f ms)",
                          loopback.meanFrames, measurement.estimate.inputFrames, measurement.totalFrames,
                          measurement.estimate.frames, measurement.estimate.milliseconds))

    let cycles = run.engine.stats().cycles
    let resumed = waitUntil(5) { run.engine.stats().cycles > cycles + 50 }
    let after = run.controller.status
    r.check(prefix + "engine-resumes", resumed && after.state == before.state && after.rebuildCount == before.rebuildCount,
            "\(describe(after.state)), \(run.engine.stats().cycles - cycles) cycles since",
            detail: "the same aggregate starts again: rebuilds \(before.rebuildCount) before, \(after.rebuildCount) after")
    Stage.set("engine running")
    return measurement
}
