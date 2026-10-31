import CoreAudio
@testable import DuetteAudio
import XCTest

/// Grouping by responsible process (WebKit helpers) and never grouping Duette itself.
final class ProcessGroupingRuleTests: XCTestCase {
    func testWebKitHelpersBelongToTheAppResponsibleForThem() {
        // Safari plays a video: the sound comes from com.apple.WebKit.GPU, which launchd starts.
        let gpu = AudioProcessInfo(objectID: 301, pid: 501, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true)
        let content = AudioProcessInfo(objectID: 302, pid: 502, bundleID: "com.apple.WebKit.WebContent")
        let mailsWebView = AudioProcessInfo(objectID: 303, pid: 503, bundleID: "com.apple.WebKit.GPU")
        let parents: [pid_t: pid_t] = [501: 1, 502: 1, 503: 1, 500: 1, 600: 1]
        let responsible: [pid_t: pid_t] = [501: 500, 502: 500, 503: 600]
        let all = [gpu, content, mailsWebView]

        let group = ProcessCatalog.processes(of: "com.apple.Safari", in: all, appPIDs: [500],
                                             parentPID: { parents[$0] }, responsiblePID: { responsible[$0] })
        XCTAssertEqual(group.map(\.objectID), [301, 302])
        let withoutLookup = ProcessCatalog.processes(of: "com.apple.Safari", in: all, appPIDs: [500],
                                                     parentPID: { parents[$0] })
        XCTAssertTrue(withoutLookup.isEmpty, "the parent chain alone ends at launchd")

        let entries = ProcessCatalog.appEntries(
            runningApps: [RunningApp(bundleID: "com.apple.Safari", name: "Safari", pid: 500),
                          RunningApp(bundleID: "com.apple.mail", name: "Mail", pid: 600)],
            processes: all, parentPID: { parents[$0] }, responsiblePID: { responsible[$0] })
        XCTAssertEqual(entries.map(\.name), ["Safari", "Mail"])
        XCTAssertEqual(entries.map(\.isPlayingAudio), [true, false])
    }

    func testDuetteItselfIsNeverPartOfAnApp() {
        // Duette started from a Terminal shell: its parent chain reaches Terminal.
        let duette = AudioProcessInfo(objectID: 401, pid: 4242, bundleID: "", isRunningOutput: true)
        let shell = AudioProcessInfo(objectID: 402, pid: 4100, bundleID: "")
        let parents: [pid_t: pid_t] = [4242: 4100, 4100: 4000, 4000: 1]
        let group = ProcessCatalog.processes(of: "com.apple.Terminal", in: [duette, shell], appPIDs: [4000],
                                             parentPID: { parents[$0] }, excludingPID: 4242)
        XCTAssertEqual(group.map(\.objectID), [402])

        let entries = ProcessCatalog.appEntries(
            runningApps: [RunningApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 4000)],
            processes: [duette, shell], parentPID: { parents[$0] }, excludingPID: 4242)
        XCTAssertEqual(entries.first?.isPlayingAudio, false, "Duette's own output does not make Terminal play")
    }
}

final class StreamBufferCheckTests: XCTestCase {
    func testStreamsImplyOneBufferPerInterleavedStreamAndOnePerChannelOtherwise() {
        let streams = [StreamInfo(id: 1, channels: 2), StreamInfo(id: 2, channels: 2, buffers: 2), StreamInfo(id: 3, channels: 1)]
        XCTAssertEqual(StreamLayoutResolver.impliedBufferChannels(streams), [2, 1, 1, 1])
        XCTAssertNoThrow(try StreamLayoutResolver.verifyBuffers(streams: streams, configuration: [2, 1, 1, 1]))
    }

    func testAMismatchWithTheStreamConfigurationThrows() {
        let streams = [StreamInfo(id: 1, channels: 2), StreamInfo(id: 2, channels: 2)]
        XCTAssertThrowsError(try StreamLayoutResolver.verifyBuffers(streams: streams, configuration: [1, 1, 2])) { error in
            XCTAssertEqual(error as? StreamLayoutError, .bufferMismatch(streams: [2, 2], configuration: [1, 1, 2]))
        }
    }
}

/// Controller behavior the review asked for, through the fake audio system.
final class ControllerReviewFixTests: XCTestCase {
    private let discord = "com.hnc.Discord"
    private var system: FakeAudioSystem!
    private var scheduler: ManualScheduler!
    private var controller: EngineController!

    override func setUp() {
        super.setUp()
        system = FakeAudioSystem()
        system.addDevice(id: 10, uid: "BuiltInMic", name: "Mic", inputChannels: 1)
        system.defaultInputUID = "BuiltInMic"
        system.apps = [RunningApp(bundleID: discord, name: "Discord", pid: 100)]
        system.processList = [AudioProcessInfo(objectID: 201, pid: 101, bundleID: "com.hnc.Discord.helper.Renderer",
                                               isRunningOutput: true)]
        system.parents = [101: 100, 100: 1]
        scheduler = ManualScheduler()
        controller = EngineController(audioSystem: system, scheduler: scheduler, ownPID: 4242)
    }

    override func tearDown() {
        controller = nil
        scheduler = nil
        system = nil
        super.tearDown()
    }

    private func feed(seconds: Double, tap: Float) throws {
        let layout = try XCTUnwrap(controller.status.layout)
        let frames = 512
        let input = SyntheticBuffers(channels: [1, 2], frames: frames)
        input.fill(layout.mic, with: 0.1)
        input.fill(layout.tap, with: tap)
        let output = SyntheticBuffers(channels: [2], frames: frames)
        for _ in 0..<Int((seconds * 48000 / Double(frames)).rounded(.up)) {
            controller.engine.process(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        }
    }

    func testAQuietAppAfterSoundIsNotAPermissionHint() throws {
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 0.2, tap: 0.3)
        try feed(seconds: 4, tap: 0)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.status.appSilentWhilePlaying, "the tap delivered sound, so capture works")
        XCTAssertTrue(controller.engine.stats().tapHadAudio)
    }

    func testSilenceFromTheStartIsStillAHint() throws {
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 4, tap: 0)
        scheduler.advance(by: 0.5)
        XCTAssertTrue(controller.status.appSilentWhilePlaying)
    }

    // MARK: Permission switched off while Duette runs

    private var hint: Bool { controller.status.appSilentWhilePlaying }

    func testPermissionSwitchedOffAfterSoundShowsTheHintWithoutARestart() throws {
        system.captureAuthorization = .authorized
        controller.start(EngineConfiguration(appBundleID: discord))
        let rebuilds = controller.status.rebuildCount
        try feed(seconds: 0.2, tap: 0.3)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(hint, "the tap carries sound")

        // System Audio Recording is switched off: the tap carries exact zeros from now on, but the
        // app keeps playing.
        try feed(seconds: 4, tap: 0)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(hint, "macOS still says it is allowed, so this is a quiet app")

        system.captureAuthorization = .denied
        scheduler.advance(by: EngineController.permissionCheckSeconds + EngineController.monitorInterval)
        XCTAssertTrue(hint, "macOS says it is denied and the tap is silent while the app plays")
        XCTAssertEqual(controller.status.rebuildCount, rebuilds, "no rebuild or restart was needed")
        XCTAssertTrue(controller.engine.stats().tapHadAudio)

        // Switched on again: the line goes away even before the app makes a sound.
        system.captureAuthorization = .authorized
        scheduler.advance(by: EngineController.permissionCheckSeconds + EngineController.monitorInterval)
        XCTAssertFalse(hint)
    }

    func testAQuietCallIsNeverAPermissionHintWhenMacOSAllowsOrDoesNotSay() throws {
        for answer in [CaptureAuthorization.authorized, .unknown] {
            let checksBefore = system.captureAuthorizationChecks
            system.captureAuthorization = answer
            controller.start(EngineConfiguration(appBundleID: discord))
            try feed(seconds: 0.2, tap: 0.3)
            try feed(seconds: 30, tap: 0)
            scheduler.advance(by: 20)
            XCTAssertFalse(hint, "\(answer): exact zeros from a playing app are a quiet call, not a denial")
            let checks = system.captureAuthorizationChecks - checksBefore
            XCTAssertGreaterThan(checks, 0, "\(answer): it did look")
            XCTAssertLessThanOrEqual(Double(checks), 20 / EngineController.permissionCheckSeconds + 1,
                                     "\(answer): macOS is asked every few seconds, not every tick")
            controller.stop()
        }
    }

    func testMacOSIsNotAskedAndNoHintShowsWhileTheAppIsNotPlaying() throws {
        system.captureAuthorization = .denied
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 0.2, tap: 0.3)
        system.processList = system.processList.map { process in
            var paused = process
            paused.isRunningOutput = false
            return paused
        }
        try feed(seconds: 4, tap: 0)
        scheduler.advance(by: 5)
        XCTAssertFalse(hint, "a muted or paused app delivers zeros whatever the permission is")
        XCTAssertEqual(system.captureAuthorizationChecks, 0)
    }

    func testMacOSIsNotAskedWhileSoundIsComingThroughOrTheSilenceIsShort() throws {
        system.captureAuthorization = .denied
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 0.2, tap: 0.3)
        try feed(seconds: 1, tap: 0.3)
        scheduler.advance(by: 3)
        XCTAssertFalse(hint, "the tap carries sound, whatever an old answer says")
        try feed(seconds: 2, tap: 0)
        scheduler.advance(by: 1)
        XCTAssertFalse(hint, "2 s of silence is a pause")
        XCTAssertEqual(system.captureAuthorizationChecks, 0)
    }

    func testSilenceFromTheStartHintsEvenWhenMacOSSaysAllowed() throws {
        // The answer is only used to confirm a loss, never to hide the hint that has always been there.
        system.captureAuthorization = .authorized
        controller.start(EngineConfiguration(appBundleID: discord))
        try feed(seconds: 4, tap: 0)
        scheduler.advance(by: 0.5)
        XCTAssertTrue(hint)
    }

    func testDuetteNeverTapsItself() {
        // Duette launched by the app it taps: its own output must stay out of the tap.
        system.processList.append(AudioProcessInfo(objectID: 299, pid: 4242, bundleID: "", isRunningOutput: true))
        system.parents[4242] = 100
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(system.createdTaps.last?.processObjectIDs, [201])
        XCTAssertEqual(controller.status.tappedPIDs, [101])
        XCTAssertFalse(controller.appChoices().contains { $0.pid == 4242 })
    }

    func testAWebKitHelperIsTappedThroughItsResponsibleApp() {
        system.apps = [RunningApp(bundleID: "com.apple.Safari", name: "Safari", pid: 500)]
        system.processList = [AudioProcessInfo(objectID: 301, pid: 501, bundleID: "com.apple.WebKit.GPU",
                                               isRunningOutput: true)]
        system.parents = [501: 1, 500: 1]
        system.responsible = [501: 500]
        controller.start(EngineConfiguration(appBundleID: "com.apple.Safari"))
        XCTAssertEqual(controller.status.state, .running(.both))
        XCTAssertEqual(system.createdTaps.last?.processObjectIDs, [301])
        XCTAssertEqual(controller.appChoices().first?.isPlayingAudio, true)
    }

    func testStopAndSleepForgetTheEngineThatRan() {
        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertNotNil(controller.status.aggregateID)
        XCTAssertEqual(controller.status.tappedPIDs, [101])

        controller.stop()
        assertCleared("after stop")

        controller.start(EngineConfiguration(appBundleID: discord))
        XCTAssertEqual(controller.status.state, .running(.both))
        system.emit(.willSleep)
        assertCleared("after sleep")
    }

    private func assertCleared(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = controller.status
        XCTAssertEqual(status.state, .idle, when, file: file, line: line)
        XCTAssertEqual(status.sources, .none, when, file: file, line: line)
        XCTAssertNil(status.aggregateID, when, file: file, line: line)
        XCTAssertNil(status.layout, when, file: file, line: line)
        XCTAssertNil(status.micUID, when, file: file, line: line)
        XCTAssertEqual(status.tappedPIDs, [], when, file: file, line: line)
        XCTAssertFalse(status.appSilentWhilePlaying, when, file: file, line: line)
        XCTAssertNil(status.sampleRate, when, file: file, line: line)
    }

    func testFailuresStartOverAfterStop() {
        let failure = OSStatus(bitPattern: FourCC.code("nope"))
        system.startErrors = [failure, failure, failure]
        controller.start(EngineConfiguration())
        scheduler.advance(by: 1.05)
        XCTAssertEqual(controller.status.state, .error(status: failure, attempt: 2))
        controller.stop()
        controller.start(EngineConfiguration())
        XCTAssertEqual(controller.status.state, .error(status: failure, attempt: 1))
    }

    func testABufferListThatDisagreesWithTheStreamsIsAnError() {
        system.bufferChannelOverride = [7]
        controller.start(EngineConfiguration(appBundleID: discord))
        guard case .error = controller.status.state else {
            return XCTFail("expected an error, got \(controller.status.state)")
        }
        XCTAssertEqual(system.ioRunning, 0)
        XCTAssertTrue(system.liveAggregates.isEmpty)
        XCTAssertTrue(system.liveTaps.isEmpty)
        system.bufferChannelOverride = nil
        scheduler.advance(by: 1.05)
        XCTAssertEqual(controller.status.state, .running(.both))
    }
}
