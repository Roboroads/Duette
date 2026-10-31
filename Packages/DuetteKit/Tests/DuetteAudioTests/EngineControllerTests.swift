import CoreAudio
@testable import DuetteAudio
import XCTest

final class EngineControllerTests: XCTestCase {
    private let discord = "com.hnc.Discord"
    private var system: FakeAudioSystem!
    private var scheduler: ManualScheduler!
    private var controller: EngineController!

    private let renderer = AudioProcessInfo(objectID: 201, pid: 101, bundleID: "com.hnc.Discord.helper.Renderer",
                                            isRunningOutput: true)
    private let helper = AudioProcessInfo(objectID: 202, pid: 102, bundleID: "com.hnc.Discord.helper")
    private let music = AudioProcessInfo(objectID: 210, pid: 300, bundleID: "com.apple.Music", isRunningOutput: true)

    override func setUp() {
        super.setUp()
        system = FakeAudioSystem()
        system.addDevice(id: 10, uid: "BuiltInMic", name: "MacBook Pro Microphone", inputChannels: 1)
        system.addDevice(id: 11, uid: "USB-Mic", name: "USB Mic", inputChannels: 2, outputChannels: 2)
        system.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        system.defaultInputUID = "BuiltInMic"
        system.parents = [101: 100, 102: 100, 100: 1, 300: 1]
        scheduler = ManualScheduler()
        controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
    }

    override func tearDown() {
        controller = nil
        scheduler = nil
        system = nil
        super.tearDown()
    }

    private func launchDiscord(withHelper: Bool = false) {
        system.apps = [RunningApp(bundleID: discord, name: "Discord", pid: 100)]
        system.processList = [renderer, music] + (withHelper ? [helper] : [])
    }

    private func quitDiscord() {
        system.apps = []
        system.processList = [music]
    }

    private var state: EngineState { controller.status.state }

    /// Emits `event` and lets the debounce run out.
    private func send(_ event: AudioSystemEvent) {
        system.emit(event)
        scheduler.advance(by: EngineController.debounceInterval + 0.01)
    }

    // MARK: Driver

    func testDriverMissingWaitsAndRunsWhenTheSinkAppears() {
        system.sinkPresent = false
        controller.start(EngineConfiguration())
        XCTAssertEqual(state, .waitingForDriver)
        XCTAssertTrue(system.createdAggregates.isEmpty)

        send(.devicesChanged)
        XCTAssertEqual(state, .waitingForDriver, "still no sink")
        XCTAssertTrue(system.createdAggregates.isEmpty)

        system.sinkPresent = true
        send(.devicesChanged)
        XCTAssertEqual(state, .running(.micOnly))
        XCTAssertEqual(system.createdAggregates.count, 1)
        XCTAssertEqual(system.ioRunning, 1)
    }

    func testSinkDisappearingStopsTheEngine() {
        controller.start(EngineConfiguration())
        XCTAssertEqual(state, .running(.micOnly))
        system.sinkPresent = false
        send(.devicesChanged)
        XCTAssertEqual(state, .waitingForDriver)
        XCTAssertEqual(system.ioRunning, 0)
        XCTAssertTrue(system.liveAggregates.isEmpty)
    }

    // MARK: App

    func testAppNotRunningGivesMicOnlyThenBothWhenItAppears() {
        quitDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(state, .waitingForApp(bundleID: discord))
        XCTAssertEqual(controller.status.sources, .micOnly, "the mic runs while waiting")
        XCTAssertEqual(system.ioRunning, 1)
        XCTAssertTrue(system.createdTaps.isEmpty)

        launchDiscord()
        send(.processesChanged)
        XCTAssertEqual(state, .running(.both))
        XCTAssertEqual(system.createdTaps.last?.processObjectIDs, [201])
        XCTAssertTrue(system.lastHasTap)
        XCTAssertEqual(controller.status.tappedPIDs, [101])
    }

    func testAppQuittingGoesBackToMicOnly() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(state, .running(.both))
        quitDiscord()
        send(.processesChanged)
        XCTAssertEqual(state, .waitingForApp(bundleID: discord))
        XCTAssertEqual(controller.status.sources, .micOnly)
        XCTAssertTrue(system.liveTaps.isEmpty, "the old tap is destroyed")
        XCTAssertFalse(system.lastHasTap)
    }

    func testHelperChangesCauseExactlyOneDebouncedRebuild() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(system.createdAggregates.count, 1)

        // Discord starts a call: a helper appears, with a burst of notifications.
        system.processList.append(helper)
        for _ in 0..<4 {
            system.emit(.processesChanged)
            scheduler.advance(by: 0.1)
        }
        XCTAssertEqual(system.createdAggregates.count, 1, "still inside the debounce")
        scheduler.advance(by: 0.3)
        XCTAssertEqual(system.createdAggregates.count, 2)
        XCTAssertEqual(Set(system.createdTaps.last?.processObjectIDs ?? []), [201, 202])
        XCTAssertEqual(system.destroyedAggregates.count, 1)
        XCTAssertEqual(system.ioRunning, 1)
    }

    func testUnrelatedProcessChangesDoNotRebuild() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        system.processList.append(AudioProcessInfo(objectID: 220, pid: 400, bundleID: "com.apple.Safari"))
        send(.processesChanged)
        XCTAssertEqual(system.createdAggregates.count, 1)
    }

    func testTapFailureKeepsTheMicRunningWithoutARetryLoop() {
        launchDiscord()
        let denied = OSStatus(bitPattern: FourCC.code("!pri"))
        system.tapErrors = [denied]
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(state, .running(.micOnly))
        XCTAssertEqual(controller.status.tapError?.status, denied)
        scheduler.advance(by: 30)
        XCTAssertEqual(system.createdAggregates.count, 1, "a failing tap does not cause rebuilds on its own")

        system.processList.append(helper)
        send(.processesChanged)
        XCTAssertEqual(state, .running(.both), "the next trigger tries again")
        XCTAssertNil(controller.status.tapError)
    }

    // MARK: Mic

    func testMicUnpluggedGivesAppOnlyAndTheSameUIDBringsItBack() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord, mic: .device(uid: "USB-Mic")))
        XCTAssertEqual(state, .running(.both))
        XCTAssertEqual(system.lastMicUID, "USB-Mic")

        system.removeDevice(uid: "USB-Mic")
        send(.devicesChanged)
        XCTAssertEqual(state, .running(.appOnly))
        XCTAssertNil(system.lastMicUID)

        system.addDevice(id: 31, uid: "USB-Mic", name: "USB Mic", inputChannels: 2)
        send(.devicesChanged)
        XCTAssertEqual(state, .running(.both))
        XCTAssertEqual(system.lastMicUID, "USB-Mic")
        XCTAssertEqual(system.createdAggregates.count, 3)
    }

    func testSystemDefaultFollowsTheDefaultInput() {
        controller.start(EngineConfiguration(mic: .systemDefault))
        XCTAssertEqual(system.lastMicUID, "BuiltInMic")
        system.defaultInputUID = "USB-Mic"
        send(.defaultInputChanged)
        XCTAssertEqual(system.lastMicUID, "USB-Mic")
        XCTAssertEqual(controller.status.micUID, "USB-Mic")
    }

    func testAChosenMicIgnoresDefaultInputChanges() {
        controller.start(EngineConfiguration(mic: .device(uid: "BuiltInMic")))
        system.defaultInputUID = "USB-Mic"
        send(.defaultInputChanged)
        XCTAssertEqual(system.createdAggregates.count, 1)
        XCTAssertEqual(system.lastMicUID, "BuiltInMic")
    }

    func testDuetteIsNeverTheMic() {
        system.defaultInputUID = DuetteDriver.deviceUID
        controller.start(EngineConfiguration(mic: .systemDefault))
        XCTAssertNil(system.lastMicUID)
        XCTAssertEqual(state, .running(.none))

        controller.update(EngineConfiguration(mic: .device(uid: DuetteDriver.deviceUID)))
        scheduler.advance(by: 1)
        XCTAssertNil(system.lastMicUID)
        XCTAssertFalse(controller.micChoices().contains { $0.selection == .device(uid: DuetteDriver.deviceUID) })
        XCTAssertEqual(controller.micChoices().first?.selection, .systemDefault)
    }

    func testUnrelatedDeviceChangesDoNotRebuild() {
        controller.start(EngineConfiguration())
        system.addDevice(id: 40, uid: "Speakers", name: "Speakers", inputChannels: 0, outputChannels: 2)
        send(.devicesChanged)
        XCTAssertEqual(system.createdAggregates.count, 1)
    }

    func testMemberSampleRateChangeRebuilds() {
        controller.start(EngineConfiguration())
        XCTAssertEqual(system.watchedDevices, [system.sinkID, 10])
        send(.deviceChanged(10))
        XCTAssertEqual(system.createdAggregates.count, 1, "nothing actually changed")
        system.rates[10] = 44100
        send(.deviceChanged(10))
        XCTAssertEqual(system.createdAggregates.count, 2)
    }

    // MARK: System

    func testCoreAudioRestartRebuildsEverything() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        send(.serviceRestarted)
        XCTAssertEqual(system.createdAggregates.count, 2)
        XCTAssertEqual(system.createdTaps.count, 2)
        XCTAssertEqual(system.ioRunning, 1)
        XCTAssertEqual(state, .running(.both))
    }

    func testSleepStopsAndWakeRebuilds() {
        controller.start(EngineConfiguration())
        system.emit(.willSleep)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(system.ioRunning, 0)
        XCTAssertTrue(system.liveAggregates.isEmpty)
        send(.devicesChanged)
        XCTAssertEqual(system.createdAggregates.count, 1, "nothing is built while asleep")

        send(.didWake)
        XCTAssertEqual(state, .running(.micOnly))
        XCTAssertEqual(system.createdAggregates.count, 2)
    }

    func testStartFailureRetriesAfterOneTwoFiveFiveSeconds() {
        let failure = OSStatus(bitPattern: FourCC.code("nope"))
        system.startErrors = [failure, failure, failure, failure]
        controller.start(EngineConfiguration())
        XCTAssertEqual(state, .error(status: failure, attempt: 1))
        XCTAssertEqual(controller.status.lastError?.status, failure)

        let expected: [(TimeInterval, EngineState)] = [
            (1, .error(status: failure, attempt: 2)),
            (2, .error(status: failure, attempt: 3)),
            (5, .error(status: failure, attempt: 4)),
            (5, .running(.micOnly)),
        ]
        for (index, (delay, next)) in expected.enumerated() {
            scheduler.advance(by: delay - 0.1)
            XCTAssertEqual(system.createdAggregates.count, index + 1, "not before \(delay) s")
            scheduler.advance(by: 0.1)
            XCTAssertEqual(state, next)
        }
        XCTAssertEqual(system.createdAggregates.count, 5)
        XCTAssertEqual(system.destroyedAggregates.count, 4, "every failed build is cleaned up")
        XCTAssertEqual(controller.status.lastError?.status, failure, "kept for diagnostics")
    }

    func testAggregateFailureIsRetriedToo() {
        launchDiscord()
        system.aggregateErrors = [OSStatus(bitPattern: FourCC.code("what"))]
        controller.start(EngineConfiguration(appBundleID: discord))
        guard case .error = state else { return XCTFail("expected an error, got \(state)") }
        XCTAssertTrue(system.liveTaps.isEmpty, "the tap of the failed build is destroyed")
        scheduler.advance(by: 1.1)
        XCTAssertEqual(state, .running(.both))
    }

    func testBufferSizeChangeRebuildsWithTheNewSize() {
        controller.start(EngineConfiguration())
        XCTAssertEqual(system.bufferSizes, [128])
        controller.update(EngineConfiguration(bufferFrameSize: 256))
        scheduler.advance(by: 0.3)
        XCTAssertEqual(system.bufferSizes, [128, 256])
        XCTAssertEqual(system.createdAggregates.count, 2)
        controller.update(EngineConfiguration(bufferFrameSize: 256))
        scheduler.advance(by: 0.3)
        XCTAssertEqual(system.createdAggregates.count, 2, "the same configuration changes nothing")
    }

    func testOverloadsOfTheAggregateAreCounted() {
        controller.start(EngineConfiguration())
        let aggregate = try? XCTUnwrap(controller.status.aggregateID)
        system.emit(.overload(aggregate ?? 0))
        system.emit(.overload(12345))
        XCTAssertEqual(controller.engine.stats().overloads, 1)
    }

    func testStopTearsEverythingDown() {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        controller.stop()
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(system.ioRunning, 0)
        XCTAssertTrue(system.liveAggregates.isEmpty)
        XCTAssertTrue(system.liveTaps.isEmpty)
        send(.processesChanged)
        XCTAssertEqual(system.createdAggregates.count, 1)
    }

    // MARK: Layout and permission hint

    func testEngineLayoutComesFromTheAggregate() throws {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        let layout = try XCTUnwrap(controller.status.layout)
        // Mono built-in mic first (a subdevice), then the stereo tap.
        XCTAssertEqual(layout.mic, BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.tap, BufferRange(first: 1, count: 1))
        XCTAssertEqual(layout.output, BufferRange(first: 0, count: 1))
        XCTAssertEqual(controller.status.inputLayoutMethod, .channelCounts)
    }

    /// Feeds the engine `seconds` of audio through its configured layout.
    private func feed(seconds: Double, tap: Float, mic: Float) throws {
        let layout = try XCTUnwrap(controller.status.layout)
        let frames = 512
        let input = SyntheticBuffers(channels: [1, 2], frames: frames)
        input.fill(layout.mic, with: mic)
        input.fill(layout.tap, with: tap)
        let output = SyntheticBuffers(channels: [2], frames: frames)
        let cycles = Int((seconds * 48000 / Double(frames)).rounded(.up))
        for _ in 0..<cycles {
            controller.engine.process(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        }
    }

    func testDeniedCaptureSilenceSetsTheHintAndAudioClearsIt() throws {
        launchDiscord()
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 2, tap: 0, mic: 0.2)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.status.appSilentWhilePlaying, "2 s of silence is not enough")

        try feed(seconds: 1.5, tap: 0, mic: 0.2)
        scheduler.advance(by: 0.5)
        XCTAssertTrue(controller.status.appSilentWhilePlaying)

        try feed(seconds: 0.1, tap: 0.3, mic: 0.2)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.status.appSilentWhilePlaying)
    }

    func testSilenceFromAnAppThatIsNotPlayingIsNotAHint() throws {
        launchDiscord()
        system.processList = system.processList.map { process in
            var paused = process
            paused.isRunningOutput = false
            return paused
        }
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 4, tap: 0, mic: 0.2)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.status.appSilentWhilePlaying)
    }

    func testStatusChangesAreReported() {
        var seen: [EngineState] = []
        controller.onStatusChange = { seen.append($0.state) }
        system.sinkPresent = false
        controller.start(EngineConfiguration())
        system.sinkPresent = true
        send(.devicesChanged)
        XCTAssertTrue(seen.contains(.waitingForDriver))
        XCTAssertEqual(seen.last, .running(.micOnly))
    }
}
