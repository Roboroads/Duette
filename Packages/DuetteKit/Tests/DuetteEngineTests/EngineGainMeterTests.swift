import CoreAudio
import DuetteEngine
import DuetteEngineTestSupport
import XCTest

/// M4: gains, mutes, meters, counters and the test tone.
final class EngineGainMeterTests: XCTestCase {
    private var engine: OpaquePointer!
    private let frames = 480  // two 5 ms ramps at 48 kHz
    private var input: TestBufferList!
    private var output: TestBufferList!

    override func setUp() {
        super.setUp()
        engine = duette_engine_create()
        // Tap (stereo, 0.4) in buffer 0, mic (mono, 0.3) in buffer 1.
        input = TestBufferList(channels: [2, 1], frames: frames)
        input.fill(0, with: 0.4)
        input.fill(1, with: 0.3)
        output = TestBufferList(channels: [2], frames: frames)
    }

    override func tearDown() {
        duette_engine_destroy(engine)
        engine = nil
        input = nil
        output = nil
        super.tearDown()
    }

    private func configure(file: StaticString = #filePath, line: UInt = #line) {
        var layout = duette_layout(mic: range(1, 1), tap: range(0, 1), output: range(0, 1), sample_rate: 48000)
        XCTAssertEqual(duette_engine_configure(engine, &layout), DUETTE_STATUS_OK, file: file, line: line)
    }

    private func left(_ frame: Int) -> Float { output.sample(0, channel: 0, frame: frame) }

    private func stats() -> duette_stats {
        var stats = duette_stats()
        duette_engine_read_stats(engine, &stats)
        return stats
    }

    private func meters() -> duette_meters {
        var meters = duette_meters()
        duette_engine_read_meters(engine, &meters)
        return meters
    }

    func testGainsSetBeforeStartApplyFromTheFirstFrame() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, 0.5)
        duette_engine_set_mute(engine, DUETTE_SOURCE_MIC, true)
        configure()
        runCycle(engine, input: input, output: output)
        for frame in 0..<frames { XCTAssertEqual(left(frame), 0.2, accuracy: 1e-6) }
    }

    func testGainChangeRampsOverFiveMilliseconds() {
        configure()
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(left(0), 0.7, accuracy: 1e-6)
        duette_engine_set_gain(engine, DUETTE_SOURCE_MIC, 2.0)
        runCycle(engine, input: input, output: output)
        // 240 frames from 0.4 + 0.3 to 0.4 + 0.6, never past the target, exact afterwards.
        XCTAssertGreaterThan(left(0), 0.7)
        XCTAssertLessThan(left(0), 0.71)
        var previous: Float = 0.7
        for frame in 0..<240 {
            XCTAssertGreaterThanOrEqual(left(frame), previous)
            XCTAssertLessThanOrEqual(left(frame), 1.0)
            previous = left(frame)
        }
        for frame in 239..<frames { XCTAssertEqual(left(frame), 1.0, accuracy: 1e-6) }
    }

    func testMuteGivesExactSilenceAndUnmuteRestoresTheGain() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_MIC, 0.5)
        configure()
        duette_engine_set_mute(engine, DUETTE_SOURCE_APP, true)
        duette_engine_set_mute(engine, DUETTE_SOURCE_MIC, true)
        runCycle(engine, input: input, output: output)
        for frame in 240..<frames { XCTAssertEqual(left(frame), 0) }
        XCTAssertTrue(duette_engine_muted(engine, DUETTE_SOURCE_MIC))
        XCTAssertEqual(duette_engine_gain(engine, DUETTE_SOURCE_MIC), 0.5, "mute keeps the gain")

        duette_engine_set_mute(engine, DUETTE_SOURCE_MIC, false)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(left(0), 0.15 / 240, accuracy: 1e-6, "unmute ramps up from 0")
        XCTAssertEqual(left(frames - 1), 0.15, accuracy: 1e-6)
    }

    func testOutputGainAndMuteApplyToTheWholeMix() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_OUTPUT, 0.5)
        configure()
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(left(0), 0.35, accuracy: 1e-6)
        duette_engine_set_mute(engine, DUETTE_SOURCE_OUTPUT, true)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(left(frames - 1), 0)
    }

    func testOutputGainAboveOneIsClipped() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_OUTPUT, 2.0)
        configure()
        runCycle(engine, input: input, output: output)
        for frame in 0..<frames { XCTAssertEqual(left(frame), 1.0) }
    }

    func testGainsAreLimitedToZeroThroughTwo() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, 7)
        XCTAssertEqual(duette_engine_gain(engine, DUETTE_SOURCE_APP), 2)
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, .nan)
        XCTAssertEqual(duette_engine_gain(engine, DUETTE_SOURCE_APP), 2, "NaN is ignored")
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, -.infinity)
        XCTAssertEqual(duette_engine_gain(engine, DUETTE_SOURCE_APP), 2, "infinity is ignored")
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, -1)
        XCTAssertEqual(duette_engine_gain(engine, DUETTE_SOURCE_APP), 0)
    }

    func testMetersShowSourcesBeforeTheirGainAndTheOutputAsSent() {
        duette_engine_set_gain(engine, DUETTE_SOURCE_APP, 0.5)
        duette_engine_set_mute(engine, DUETTE_SOURCE_MIC, true)
        configure()
        runCycle(engine, input: input, output: output)
        let levels = meters()
        XCTAssertEqual(levels.app.peak, 0.4, accuracy: 1e-6)
        XCTAssertEqual(levels.app.rms, 0.4, accuracy: 1e-6)
        XCTAssertEqual(levels.mic.peak, 0.3, accuracy: 1e-6, "a muted mic still shows its level")
        XCTAssertEqual(levels.output.peak, 0.2, accuracy: 1e-6)
        XCTAssertEqual(levels.output.rms, 0.2, accuracy: 1e-6)
    }

    func testMetersOfASine() {
        configure()
        let tapOnly = TestBufferList(channels: [2, 1], frames: frames)
        let step: Float = 2 * Float.pi * 1000 / 48000
        let sine: (Int) -> Float = { frame in 0.5 * sin(step * Float(frame)) }
        tapOnly.fill(0, channel: 0, sine)
        tapOnly.fill(0, channel: 1, sine)
        runCycle(engine, input: tapOnly, output: output)
        let levels = meters()
        let expectedRMS: Float = 0.5 / Float(2).squareRoot()
        XCTAssertEqual(levels.app.peak, 0.5, accuracy: 1e-3)
        XCTAssertEqual(levels.app.rms, expectedRMS, accuracy: 1e-3)
        XCTAssertEqual(levels.output.rms, expectedRMS, accuracy: 1e-3)
    }

    func testCountersAndHostTime() {
        configure()
        let before = stats()
        runCycle(engine, input: input, output: output, hostTime: 777)
        runCycle(engine, input: input, output: output, hostTime: 778)
        let after = stats()
        XCTAssertEqual(after.cycles - before.cycles, 2)
        XCTAssertEqual(after.frames - before.frames, UInt64(2 * frames))
        XCTAssertEqual(after.last_host_time, 778)
        duette_engine_count_overload(engine)
        XCTAssertEqual(stats().overloads, before.overloads + 1)
    }

    func testZeroRunsCountSilentFramesAndResetOnSound() {
        configure()
        input.fill(0, with: 0)
        runCycle(engine, input: input, output: output)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(stats().tap_zero_frames, UInt64(2 * frames))
        XCTAssertEqual(stats().mic_zero_frames, 0)
        input.set(0, channel: 1, frame: frames - 10, to: 1e-9)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(stats().tap_zero_frames, 9)
    }

    func testConfigureResetsZeroRunsAndAbsentSourcesReadZero() {
        configure()
        input.fill(0, with: 0)
        runCycle(engine, input: input, output: output)
        XCTAssertGreaterThan(stats().tap_zero_frames, 0)
        var micOnly = duette_layout(mic: range(1, 1), tap: range(0, 0), output: range(0, 1), sample_rate: 48000)
        XCTAssertEqual(duette_engine_configure(engine, &micOnly), DUETTE_STATUS_OK)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(stats().tap_zero_frames, 0)
    }

    func testMismatchedBufferListsAreCounted() {
        configure()
        let tooFew = TestBufferList(channels: [2], frames: frames, fill: 0.4)
        let before = stats().layout_mismatches
        runCycle(engine, input: tooFew, output: output)
        XCTAssertEqual(stats().layout_mismatches, before + 1)
        // The tap still plays; only the missing mic is left out.
        XCTAssertEqual(left(0), 0.4, accuracy: 1e-6)
    }

    func testTestToneReplacesTheMix() {
        configure()
        duette_engine_set_test_tone(engine, true)
        XCTAssertTrue(duette_engine_test_tone(engine))
        runCycle(engine, input: input, output: output)  // fade in
        var peak: Float = 0
        var crossings = 0
        var previous: Float = 0
        let cycles = 100
        for _ in 0..<cycles {
            runCycle(engine, input: input, output: output)
            for frame in 0..<frames {
                let value = left(frame)
                XCTAssertEqual(output.sample(0, channel: 1, frame: frame), value)
                peak = max(peak, abs(value))
                if previous < 0 && value >= 0 { crossings += 1 }
                previous = value
            }
        }
        XCTAssertEqual(peak, 0.2512, accuracy: 1e-3, "-12 dBFS")
        let seconds = Double(cycles * frames) / 48000
        XCTAssertEqual(Double(crossings) / seconds, 440, accuracy: 3)

        duette_engine_set_test_tone(engine, false)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(left(frames - 1), 0.7, accuracy: 1e-6, "the mix is back after the fade")
    }

    func testIOProcWithChangingParametersDoesNotAllocate() {
        configure()
        runCycle(engine, input: input, output: output)
        duette_alloc_counter_arm()
        for cycle in 0..<300 {
            duette_engine_set_gain(engine, DUETTE_SOURCE_APP, Float(cycle % 5) / 2)
            duette_engine_set_mute(engine, DUETTE_SOURCE_MIC, cycle % 3 == 0)
            duette_engine_set_test_tone(engine, cycle % 7 == 0)
            runCycle(engine, input: input, output: output, hostTime: UInt64(cycle + 1))
            var meters = duette_meters()
            duette_engine_read_meters(engine, &meters)
            var stats = duette_stats()
            duette_engine_read_stats(engine, &stats)
        }
        XCTAssertEqual(duette_alloc_counter_disarm(), 0)
    }

    func testIOProcThreadAndControlThreadRunTogether() {
        // Run under `swift test --sanitize=thread` this proves the atomics are enough.
        configure()
        let done = DispatchSemaphore(value: 0)
        let engine = self.engine!
        let input = self.input!
        let output = self.output!
        let stop = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        stop.initialize(to: false)
        defer { stop.deallocate() }
        let lock = NSLock()
        Thread.detachNewThread {
            while true {
                lock.lock()
                let finished = stop.pointee
                lock.unlock()
                if finished { break }
                runCycle(engine, input: input, output: output, hostTime: 1)
            }
            done.signal()
        }
        for step in 0..<20_000 {
            duette_engine_set_gain(engine, DUETTE_SOURCE_MIC, Float(step % 9) / 4)
            duette_engine_set_mute(engine, DUETTE_SOURCE_APP, step % 4 == 0)
            duette_engine_set_test_tone(engine, step % 13 == 0)
            var meters = duette_meters()
            duette_engine_read_meters(engine, &meters)
            var stats = duette_stats()
            duette_engine_read_stats(engine, &stats)
            if step % 100 == 0 { duette_engine_count_overload(engine) }
        }
        lock.lock()
        stop.pointee = true
        lock.unlock()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertGreaterThan(stats().cycles, 0)
    }
}
