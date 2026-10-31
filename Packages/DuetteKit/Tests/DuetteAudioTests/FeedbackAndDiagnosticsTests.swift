import CoreAudio
@testable import DuetteAudio
import XCTest

final class FeedbackLoopDetectorTests: XCTestCase {
    func testAnAppProcessRecordingDuetteIsALoop() {
        XCTAssertEqual(FeedbackLoopDetector.loopingPIDs(inputClients: [55, 101, 7], appPIDs: [100, 101], ownPID: 4242), [101])
        XCTAssertTrue(FeedbackLoopDetector.isLoop(inputClients: [101], appPIDs: [100, 101], ownPID: 4242))
    }

    func testOtherRecordersAndDuetteItselfAreNot() {
        XCTAssertFalse(FeedbackLoopDetector.isLoop(inputClients: [55, 7], appPIDs: [100, 101], ownPID: 4242))
        XCTAssertFalse(FeedbackLoopDetector.isLoop(inputClients: [4242], appPIDs: [4242, 100], ownPID: 4242))
        XCTAssertFalse(FeedbackLoopDetector.isLoop(inputClients: [], appPIDs: [100], ownPID: 4242))
        XCTAssertFalse(FeedbackLoopDetector.isLoop(inputClients: [100], appPIDs: [], ownPID: 4242))
    }
}

/// The controller's feedback-loop warning, driven through the fake audio system.
final class FeedbackLoopControllerTests: XCTestCase {
    private let discord = "com.hnc.Discord"
    private var system: FakeAudioSystem!
    private var scheduler: ManualScheduler!
    private var controller: EngineController!

    override func setUp() {
        super.setUp()
        system = FakeAudioSystem()
        system.addDevice(id: 10, uid: "BuiltInMic", name: "Mic", inputChannels: 1)
        system.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        system.defaultInputUID = "BuiltInMic"
        system.apps = [RunningApp(bundleID: discord, name: "Discord", pid: 100)]
        // The renderer plays; the voice helper (another bundle ID, child of Discord) records.
        system.processList = [
            AudioProcessInfo(objectID: 201, pid: 101, bundleID: "com.hnc.Discord.helper.Renderer", isRunningOutput: true),
            AudioProcessInfo(objectID: 203, pid: 103, bundleID: "", isRunningInput: true),
            AudioProcessInfo(objectID: 210, pid: 300, bundleID: "com.obsproject.obs-studio", isRunningInput: true),
        ]
        system.parents = [101: 100, 103: 100, 100: 1, 300: 1]
        scheduler = ManualScheduler()
        controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
    }

    override func tearDown() {
        controller = nil
        scheduler = nil
        system = nil
        super.tearDown()
    }

    func testTheTappedAppRecordingDuetteRaisesTheWarningWithoutTouchingTheAudio() {
        system.inputClients = [300]
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertFalse(controller.status.feedbackLoop, "OBS recording Duette is the point of Duette")
        let aggregates = system.createdAggregates.count

        system.inputClients = [103, 300]
        system.emit(.inputClientsChanged)
        XCTAssertTrue(controller.status.feedbackLoop)
        XCTAssertEqual(controller.status.feedbackLoopPIDs, [103])
        scheduler.advance(by: 1)
        XCTAssertEqual(system.createdAggregates.count, aggregates, "warn only: no rebuild")
        XCTAssertEqual(system.ioRunning, 1)
        XCTAssertEqual(controller.status.state, .running(.both))

        system.inputClients = [300]
        system.emit(.inputClientsChanged)
        XCTAssertFalse(controller.status.feedbackLoop)
        XCTAssertEqual(controller.status.feedbackLoopPIDs, [])
    }

    func testALoopThatExistsAtStartIsReported() {
        system.inputClients = [101]
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertTrue(controller.status.feedbackLoop)
    }

    func testDuetteItselfIsExcluded() {
        system.inputClients = [4242]
        system.processList.append(AudioProcessInfo(objectID: 299, pid: 4242, bundleID: discord))
        controller.start(EngineConfiguration(appBundleID: discord))
        system.emit(.inputClientsChanged)
        XCTAssertFalse(controller.status.feedbackLoop)
    }

    func testNoAppNoWarningAndNoDriverNoWarning() {
        system.inputClients = [101]
        controller.start(EngineConfiguration())
        XCTAssertFalse(controller.status.feedbackLoop)
        controller.update(EngineConfiguration(appBundleID: discord))
        scheduler.advance(by: 0.3)
        XCTAssertTrue(controller.status.feedbackLoop)
        system.inputClients = nil
        system.emit(.inputClientsChanged)
        XCTAssertFalse(controller.status.feedbackLoop)
    }

    func testAHelperThatStartsRecordingLaterIsCaughtThroughTheProcessList() {
        controller.start(EngineConfiguration(appBundleID: discord))
        system.processList.append(AudioProcessInfo(objectID: 204, pid: 104, bundleID: "com.hnc.Discord.helper",
                                                   isRunningInput: true))
        system.inputClients = [104]
        system.emit(.processesChanged)
        XCTAssertTrue(controller.status.feedbackLoop)
    }
}

final class DiagnosticsTests: XCTestCase {
    func testMeterHistoryKeepsTheRangeOfTheLastMinute() {
        let history = MeterHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        history.record(Meters(app: Level(peak: 0.9, rms: 0.5)), at: start)
        history.record(Meters(app: Level(peak: 0.2, rms: 0.1), mic: Level(peak: 0.3, rms: 0.2)), at: start + 30)
        history.record(Meters(app: Level(peak: 0.4, rms: 0.3)), at: start + 70)
        let summary = history.summary(window: 60, now: start + 70)
        XCTAssertEqual(summary.samples, 2)
        XCTAssertEqual(summary.app?.minPeak, 0.2)
        XCTAssertEqual(summary.app?.maxPeak, 0.4)
        XCTAssertEqual(summary.mic?.maxRMS, 0.2)
        XCTAssertEqual(history.summary(window: 60, now: start + 1_000).samples, 0)
        XCTAssertNil(history.summary(window: 60, now: start + 1_000).app)
    }

    func testMeterHistoryIsBounded() {
        let history = MeterHistory()
        let now = Date()
        for index in 0..<(MeterHistory.capacity + 50) {
            history.record(Meters(), at: now - Double(MeterHistory.capacity + 50 - index) * 0.01)
        }
        XCTAssertEqual(history.summary(window: 1_000, now: now).samples, MeterHistory.capacity)
    }

    func testLatencyEstimateAddsEveryHop() {
        let aggregate = DeviceTiming(bufferFrameSize: 128, inputLatency: 40, outputLatency: 10,
                                     inputSafetyOffset: 20, outputSafetyOffset: 30)
        let duette = DeviceTiming(bufferFrameSize: 256, inputLatency: 0, inputSafetyOffset: 16)
        let estimate = LatencyModel.estimate(aggregate: aggregate, duette: duette, sampleRate: 48000)
        // The engine's input and output buffers, and a reader of "Duette" with the same buffer
        // size: "Duette"'s own 256 is this process's setting, not the reader's.
        let buffers: UInt32 = 128 * 3
        let aggregateHops: UInt32 = 40 + 20 + 10 + 30
        let duetteHop: UInt32 = 0 + 16
        XCTAssertEqual(estimate.frames, buffers + aggregateHops + duetteHop)
        XCTAssertEqual(estimate.milliseconds, Double(estimate.frames) / 48, accuracy: 1e-9)
        XCTAssertEqual(LatencyModel.estimate(aggregate: DeviceTiming(bufferFrameSize: 64), duette: nil, sampleRate: 48000).frames, 128)
    }

    func testReportCoversDevicesDriverAppAndEngine() throws {
        let system = FakeAudioSystem()
        system.addDevice(id: 10, uid: "BuiltInMic", name: "Mic", inputChannels: 1)
        system.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        system.defaultInputUID = "BuiltInMic"
        system.apps = [RunningApp(bundleID: "com.hnc.Discord", name: "Discord", pid: 100)]
        system.processList = [AudioProcessInfo(objectID: 201, pid: 101, bundleID: "com.hnc.Discord.helper.Renderer",
                                               isRunningOutput: true)]
        system.inputClients = [300]
        let scheduler = ManualScheduler()
        let controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
        controller.start(EngineConfiguration(appBundleID: "com.hnc.Discord", bufferFrameSize: 256))
        controller.engine.setGain(1.5, for: .mic)
        scheduler.advance(by: 2)

        let timing = DeviceTiming(bufferFrameSize: 256, inputLatency: 10, outputLatency: 10,
                                  inputSafetyOffset: 10, outputSafetyOffset: 10)
        system.loopback = .success(LoopbackMeasurement(bufferFrameSize: 256, meanFrames: 560, worstFrames: 700,
                                                       sampleOffset: 0, confidence: 1, takes: 1))
        var measured: LatencyMeasurement?
        controller.measureLatency(timing: { _ in timing }) { measured = try? $0.get() }
        let measurement = try XCTUnwrap(measured)
        let collector = DiagnosticsCollector(audioSystem: system, controller: controller,
                                             timing: { _ in timing }, selfTestTone: { false })
        let report = collector.collect(permissions: ["microphone": "authorized"], selfTests: ["driverTone": "passed"])

        XCTAssertEqual(report.devices.map(\.info.uid), ["BuiltInMic", DuetteDriver.deviceUID])
        XCTAssertTrue(report.driver.installed)
        XCTAssertEqual(report.driver.sinkID, system.sinkID)
        XCTAssertEqual(report.driver.inputClients, [300])
        XCTAssertEqual(report.driver.selfTestTone, false)
        XCTAssertEqual(report.selectedApp, "com.hnc.Discord")
        XCTAssertEqual(report.selectedAppProcesses.map(\.pid), [101])
        let engine = try XCTUnwrap(report.engine)
        XCTAssertEqual(engine.status.state, .running(.both))
        XCTAssertEqual(engine.status.configuration.bufferFrameSize, 256)
        XCTAssertEqual(engine.gains["mic"], 1.5)
        XCTAssertEqual(engine.mutes["app"], false)
        // Two 256-frame buffers and 4 x 10 on the aggregate, then 256 + 2 x 10 for "Duette".
        let expectedFrames: UInt32 = 828
        XCTAssertEqual(engine.estimatedLatency?.frames, expectedFrames)
        // The latest "Measure latency": the 276-frame input side plus the 560 frames measured.
        XCTAssertEqual(engine.measuredLatency, measurement)
        XCTAssertEqual(engine.measuredLatencyMilliseconds ?? 0, 836.0 / 48, accuracy: 1e-9)
        XCTAssertGreaterThan(engine.meters.samples, 0)
        XCTAssertEqual(report.permissions["microphone"], "authorized")
        XCTAssertEqual(report.selfTests["driverTone"], "passed")

        let json = try DiagnosticsCollector.encode(report)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"feedbackLoop\""))
        XCTAssertTrue(text.contains("\"measuredLatency\""))
        XCTAssertTrue(text.contains("\"matchesEstimate\""))
        XCTAssertTrue(text.contains("\"hardwareModel\""))
        let decoded = try JSONDecoder.withISODates().decode(DiagnosticsReport.self, from: json)
        XCTAssertEqual(decoded.engine?.status, engine.status)
    }

    @available(*, deprecated)
    func testTheOldCollectStillTakesAMeasuredLatency() throws {
        let system = FakeAudioSystem()
        system.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        let scheduler = ManualScheduler()
        let controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
        controller.start(EngineConfiguration())
        let collector = DiagnosticsCollector(audioSystem: system, controller: controller,
                                             timing: { _ in DeviceTiming(bufferFrameSize: 128) }, selfTestTone: { false })
        let report = collector.collect(permissions: [:], selfTests: [:], measuredLatencyMilliseconds: 9.5)
        XCTAssertEqual(try XCTUnwrap(report.engine).measuredLatencyMilliseconds, 9.5)
    }

    func testReportWithoutDriverOrController() {
        let system = FakeAudioSystem()
        system.sinkPresent = false
        system.inputClients = nil
        let report = DiagnosticsCollector(audioSystem: system, controller: nil, timing: { _ in DeviceTiming() },
                                          selfTestTone: { nil }).collect()
        XCTAssertFalse(report.driver.installed)
        XCTAssertNil(report.engine)
        XCTAssertNil(report.selectedApp)
        XCTAssertNoThrow(try DiagnosticsCollector.encode(report))
    }

    func testHardwareModelIsKnown() {
        XCTAssertNotEqual(DiagnosticsCollector.hardwareModel(), "unknown")
    }
}

private extension JSONDecoder {
    static func withISODates() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
