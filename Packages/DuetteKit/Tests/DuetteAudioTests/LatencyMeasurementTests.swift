import CoreAudio
@testable import DuetteAudio
import XCTest

final class LatencyMeasurementTests: XCTestCase {
    // MARK: The estimate

    func testTheEstimateSplitsIntoTheEnginesInputAndTheLoopback() {
        let aggregate = DeviceTiming(bufferFrameSize: 128, inputLatency: 40, outputLatency: 10,
                                     inputSafetyOffset: 20, outputSafetyOffset: 30)
        let duette = DeviceTiming(bufferFrameSize: 512, inputLatency: 2, inputSafetyOffset: 16)
        let estimate = LatencyModel.estimate(aggregate: aggregate, duette: duette, sampleRate: 48000)
        XCTAssertEqual(estimate.inputFrames, 128 + 40 + 20)
        // Into the sink, then a reader of "Duette" at the engine's buffer size: the 512 is this
        // process's own setting on "Duette", not any reader's.
        XCTAssertEqual(estimate.loopbackFrames, 128 + 10 + 30 + 128 + 2 + 16)
        XCTAssertEqual(estimate.frames, estimate.inputFrames + estimate.loopbackFrames)
        XCTAssertEqual(estimate.milliseconds, Double(estimate.frames) / 48, accuracy: 1e-9)
    }

    func testWithoutTheDriverOnlyTheEnginesBuffersCount() {
        let estimate = LatencyModel.estimate(aggregate: DeviceTiming(bufferFrameSize: 64), duette: nil, sampleRate: 48000)
        XCTAssertEqual(estimate.inputFrames, 64)
        XCTAssertEqual(estimate.loopbackFrames, 64)
        XCTAssertEqual(estimate.frames, 128)
    }

    func testTheRunnersHALFiguresGiveTheLoopbackItMeasured() {
        // The CI runner (S6): latencies 0, the sink's safety offset 0, "Duette"'s 16. The loopback
        // measured 275 frames at 128 and 144 at 64; the HAL figures add up to 272 and 144.
        let duette = DeviceTiming(bufferFrameSize: 512, inputLatency: 0, inputSafetyOffset: 16)
        for (buffer, measured) in [(UInt32(128), 275.0), (64, 144.0)] {
            let aggregate = DeviceTiming(bufferFrameSize: buffer, inputLatency: 0, outputLatency: 0,
                                         inputSafetyOffset: 0, outputSafetyOffset: 0)
            let estimate = LatencyModel.estimate(aggregate: aggregate, duette: duette, sampleRate: 48000)
            XCTAssertEqual(estimate.loopbackFrames, buffer * 2 + 16)
            XCTAssertLessThanOrEqual(abs(measured - Double(estimate.loopbackFrames)) / 48, LatencyModel.toleranceMilliseconds)
        }
    }

    // MARK: A measurement

    private let runnerEstimate = LatencyModel.estimate(
        aggregate: DeviceTiming(bufferFrameSize: 128, inputLatency: 20, outputLatency: 0, inputSafetyOffset: 8,
                                outputSafetyOffset: 0),
        duette: DeviceTiming(inputLatency: 0, inputSafetyOffset: 16), sampleRate: 48000)

    private func loopback(_ meanFrames: Double) -> LoopbackMeasurement {
        LoopbackMeasurement(bufferFrameSize: 128, meanFrames: meanFrames, worstFrames: meanFrames + 100, sampleOffset: 0,
                            confidence: 1, takes: 1)
    }

    func testAMeasurementAddsTheEnginesInputToTheMeasuredLoopback() {
        let measurement = LatencyMeasurement(date: Date(timeIntervalSince1970: 0), loopback: loopback(275),
                                             estimate: runnerEstimate, sampleRate: 48000)
        XCTAssertEqual(runnerEstimate.inputFrames, 156)
        XCTAssertEqual(runnerEstimate.loopbackFrames, 272)
        XCTAssertEqual(measurement.totalFrames, 156 + 275)
        XCTAssertEqual(measurement.totalMilliseconds, 431.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(measurement.differenceMilliseconds, 3.0 / 48, accuracy: 1e-9)
        XCTAssertTrue(measurement.matchesEstimate)
    }

    func testALoopbackMoreThanAMillisecondFromTheEstimateDoesNotMatch() {
        func matches(_ mean: Double) -> Bool {
            LatencyMeasurement(date: Date(), loopback: loopback(mean), estimate: runnerEstimate, sampleRate: 48000).matchesEstimate
        }
        XCTAssertTrue(matches(272 + 48))
        XCTAssertTrue(matches(272 - 48))
        XCTAssertFalse(matches(272 + 49))
        XCTAssertFalse(matches(272 - 49))
        let late = LatencyMeasurement(date: Date(), loopback: loopback(272 + 96), estimate: runnerEstimate, sampleRate: 48000)
        XCTAssertEqual(late.differenceMilliseconds, 2, accuracy: 1e-9)
    }

    func testAMeasurementSurvivesJSON() throws {
        let measurement = LatencyMeasurement(date: Date(timeIntervalSince1970: 1_000), loopback: loopback(275),
                                             estimate: runnerEstimate, sampleRate: 48000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(LatencyMeasurement.self, from: encoder.encode(measurement)), measurement)
    }

    // MARK: EngineController.measureLatency

    private var system: FakeAudioSystem!
    private var scheduler: ManualScheduler!
    private var controller: EngineController!

    override func setUp() {
        super.setUp()
        system = FakeAudioSystem()
        system.addDevice(id: 10, uid: "BuiltInMic", name: "MacBook Pro Microphone", inputChannels: 1)
        system.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        system.defaultInputUID = "BuiltInMic"
        scheduler = ManualScheduler()
        controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
    }

    override func tearDown() {
        controller = nil
        scheduler = nil
        system = nil
        super.tearDown()
    }

    private let timing: (AudioObjectID) -> DeviceTiming = { device in
        // "Duette" (12) has its 16-frame safety offset; everything else just the buffer.
        device == 12 ? DeviceTiming(bufferFrameSize: 512, inputSafetyOffset: 16) : DeviceTiming(bufferFrameSize: 64)
    }

    private func measure() -> Result<LatencyMeasurement, LatencyMeasurementError>? {
        var result: Result<LatencyMeasurement, LatencyMeasurementError>?
        controller.measureLatency(timing: timing, now: { Date(timeIntervalSince1970: 42) }) { result = $0 }
        return result
    }

    private func failure(_ result: Result<LatencyMeasurement, LatencyMeasurementError>?) -> LatencyMeasurementError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    func testMeasuringPausesTheEngineMeasuresTheSinkAndResumes() throws {
        system.loopback = .success(LoopbackMeasurement(bufferFrameSize: 64, meanFrames: 146, worstFrames: 200,
                                                       sampleOffset: 0, confidence: 1, takes: 1))
        controller.start(EngineConfiguration(bufferFrameSize: 64))
        XCTAssertEqual(controller.status.state, .running(.micOnly))
        let aggregate = try XCTUnwrap(controller.status.aggregateID)

        let measurement = try XCTUnwrap(measure()).get()

        XCTAssertEqual(system.loopbackCalls, [FakeAudioSystem.LoopbackCall(sink: system.sinkID, duette: 12,
                                                                           bufferFrameSize: 64, ioRunning: 0)],
                       "the probe is the sink's only writer: the engine's IOProc is stopped meanwhile")
        XCTAssertEqual(system.startedIO, [aggregate, aggregate], "the same aggregate runs again")
        XCTAssertEqual(system.ioRunning, 1)
        XCTAssertEqual(system.destroyedAggregates, [], "a pause, not a rebuild")
        XCTAssertEqual(controller.status.rebuildCount, 1)
        XCTAssertEqual(controller.status.state, .running(.micOnly))

        XCTAssertEqual(measurement.date, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(measurement.loopback.meanFrames, 146)
        XCTAssertEqual(measurement.estimate.inputFrames, 64)
        XCTAssertEqual(measurement.estimate.loopbackFrames, 64 + 64 + 16)
        XCTAssertEqual(measurement.totalFrames, 64 + 146)
        XCTAssertTrue(measurement.matchesEstimate)
        XCTAssertEqual(controller.latestLatencyMeasurement, measurement)
    }

    func testNothingIsMeasuredWhileTheEngineIsNotRunning() {
        XCTAssertEqual(failure(measure()), .notRunning, "not started")

        system.sinkPresent = false
        controller.start(EngineConfiguration())
        XCTAssertEqual(controller.status.state, .waitingForDriver)
        XCTAssertEqual(failure(measure()), .notRunning, "no driver, no engine")
        XCTAssertTrue(system.loopbackCalls.isEmpty)
        XCTAssertNil(controller.latestLatencyMeasurement)
    }

    func testAMissingDuetteDeviceIsSaidSo() {
        system.removeDevice(uid: DuetteDriver.deviceUID)
        controller.start(EngineConfiguration())
        XCTAssertEqual(failure(measure()), .driverMissing)
        XCTAssertEqual(system.ioRunning, 1, "the engine was never paused")
        XCTAssertTrue(system.loopbackCalls.isEmpty)
    }

    func testAChirpThatNeverArrivesIsReportedAndTheEngineStillResumes() {
        system.loopback = .failure(LatencyMeasurementError.notHeard)
        controller.start(EngineConfiguration())
        XCTAssertEqual(failure(measure()), .notHeard)
        XCTAssertEqual(system.ioRunning, 1)
        XCTAssertEqual(controller.status.state, .running(.micOnly))
        XCTAssertNil(controller.latestLatencyMeasurement)
    }

    func testACoreAudioFailureIsPassedOn() {
        let error = CoreAudioError(OSStatus(kAudioHardwareNotRunningError), "start recording from Duette")
        system.loopback = .failure(error)
        controller.start(EngineConfiguration())
        XCTAssertEqual(failure(measure()), .failed(error))
        XCTAssertEqual(system.ioRunning, 1)
    }

    func testAnEngineThatWillNotStartAgainIsRebuiltWithBackoff() throws {
        controller.start(EngineConfiguration())
        let first = try XCTUnwrap(controller.status.aggregateID)
        system.startErrors = [OSStatus(kAudioHardwareUnspecifiedError)]

        XCTAssertNotNil(try XCTUnwrap(measure()).get(), "the measurement itself worked")
        XCTAssertEqual(controller.status.state, .error(status: OSStatus(kAudioHardwareUnspecifiedError), attempt: 1))
        XCTAssertEqual(system.destroyedAggregates, [first], "the broken aggregate is torn down")
        XCTAssertEqual(system.ioRunning, 0)

        scheduler.advance(by: EngineController.retryDelays[0] + 0.01)
        XCTAssertEqual(controller.status.state, .running(.micOnly))
        XCTAssertEqual(system.ioRunning, 1)
    }
}
