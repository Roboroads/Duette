import CoreAudio
import DuetteAudio
import XCTest

final class AppModelTests: XCTestCase {
    private var world: World!

    override func setUp() {
        super.setUp()
        world = World()
    }

    override func tearDown() {
        world = nil
        super.tearDown()
    }

    // MARK: Defaults on the first run

    func testFirstRunPreselectsDiscordWhenItIsInstalled() {
        world.installedApps = [World.discord]
        let model = world.makeModel()
        XCTAssertEqual(model.appBundleID, World.discord)
        XCTAssertEqual(model.mic, .systemDefault)
        for source in MixSource.allCases {
            XCTAssertEqual(model.gain(for: source), 1)
            XCTAssertFalse(model.isMuted(source))
        }
        XCTAssertEqual(model.bufferFrameSize, 128)
        XCTAssertEqual(world.makeSettings().appBundleID, World.discord, "the default is saved, so it sticks")
    }

    func testFirstRunWithoutDiscordStartsWithoutAnApp() {
        let model = world.makeModel()
        XCTAssertNil(model.appBundleID)
        XCTAssertEqual(model.mic, .systemDefault)
    }

    func testAChoiceOfNoAppIsKeptEvenWhenDiscordIsInstalledLater() {
        let first = world.makeModel()
        first.selectApp(nil)
        world.installedApps = [World.discord]
        let second = world.makeModel()
        XCTAssertNil(second.appBundleID, "only the very first launch preselects Discord")
    }

    func testTheFirstRunWorksWithZeroChoices() {
        world.installedApps = [World.discord]
        world.launchDiscord()
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(model.status.state, .running(.both))
        XCTAssertEqual(model.statusLine.tone, .good)
        XCTAssertEqual(world.audio.ioRunning, 1)
    }

    // MARK: Persistence

    func testSelectionsAndMixSettingsSurviveARestart() {
        let first = world.makeModel()
        first.selectApp(World.music)
        first.selectMic(.device(uid: "USB-Mic"))
        first.setGain(0.5, for: .app)
        first.setGain(1.5, for: .mic)
        first.setMuted(true, for: .output)
        first.setBufferFrameSize(256)

        let second = world.makeModel()
        XCTAssertEqual(second.appBundleID, World.music)
        XCTAssertEqual(second.mic, .device(uid: "USB-Mic"))
        XCTAssertEqual(second.gain(for: .app), 0.5)
        XCTAssertEqual(second.gain(for: .mic), 1.5)
        XCTAssertEqual(second.gain(for: .output), 1)
        XCTAssertTrue(second.isMuted(.output))
        XCTAssertFalse(second.isMuted(.app))
        XCTAssertEqual(second.bufferFrameSize, 256)
    }

    func testStoredGainsAndMutesReachTheEngineWhenItStarts() {
        let first = world.makeModel()
        first.setGain(0.25, for: .mic)
        first.setMuted(true, for: .app)

        let second = world.makeModel()
        second.start()
        XCTAssertEqual(second.controller.engine.gain(for: .mic), 0.25)
        XCTAssertTrue(second.controller.engine.isMuted(.app))
        XCTAssertFalse(second.controller.engine.isMuted(.mic))
    }

    func testGainsAreClampedToZeroToTwo() {
        let model = world.makeModel()
        model.setGain(5, for: .app)
        XCTAssertEqual(model.gain(for: .app), 2)
        XCTAssertEqual(model.controller.engine.gain(for: .app), 2)
        model.setGain(-1, for: .app)
        XCTAssertEqual(model.gain(for: .app), 0)
        XCTAssertEqual(model.controller.engine.gain(for: .app), 0)
        model.setGain(.nan, for: .mic)
        XCTAssertEqual(model.gain(for: .mic), 1)
        XCTAssertEqual(world.makeSettings().gain(.app), 0, "the clamped value is what is saved")
    }

    func testMutingKeepsTheGain() {
        let model = world.makeModel()
        model.setGain(0.75, for: .mic)
        model.setMuted(true, for: .mic)
        XCTAssertTrue(model.controller.engine.isMuted(.mic))
        XCTAssertEqual(model.gain(for: .mic), 0.75)
        model.setMuted(false, for: .mic)
        XCTAssertFalse(model.controller.engine.isMuted(.mic))
    }

    // MARK: Restoring a choice that is not there

    func testARestoredAppThatIsNotRunningShowsWaiting() {
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = "com.example.Gone"
        let model = world.makeModel(settings: settings)
        model.start()
        XCTAssertEqual(model.status.state, .waitingForApp(bundleID: "com.example.Gone"))
        XCTAssertEqual(model.statusLine.tone, .waiting)
        XCTAssertEqual(model.statusLine.message, "Waiting for Gone to start")
        XCTAssertTrue(world.audio.createdTaps.isEmpty)
    }

    func testTheRestoredAppIsPickedUpWhenItStarts() {
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = World.discord
        let model = world.makeModel(settings: settings)
        model.start()
        XCTAssertEqual(model.status.state, .waitingForApp(bundleID: World.discord))

        world.launchDiscord()
        world.audio.emit(.processesChanged)
        world.settle()
        XCTAssertEqual(model.status.state, .running(.both))
        XCTAssertEqual(model.statusLine.tone, .good)
    }

    func testARestoredMicThatIsMissingShowsItAndComesBackWithTheSameUID() {
        world.launchMusic()
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = World.music
        settings.mic = .device(uid: "Headset")
        let model = world.makeModel(settings: settings)
        model.start()
        XCTAssertEqual(model.status.state, .running(.appOnly))
        XCTAssertEqual(model.statusLine.tone, .waiting)
        XCTAssertEqual(model.statusLine.message, "Your microphone isn't connected")

        world.audio.addDevice(id: 13, uid: "Headset", name: "Headset", inputChannels: 1)
        world.audio.emit(.devicesChanged)
        world.settle()
        XCTAssertEqual(model.status.state, .running(.both))
        XCTAssertEqual(model.statusLine.tone, .good)
    }

    // MARK: Changing things while it runs

    func testChangingTheAppRebuildsTheEngineForTheNewApp() {
        world.launchDiscord()
        world.launchMusic()
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = World.discord
        let model = world.makeModel(settings: settings)
        model.start()
        XCTAssertEqual(world.audio.createdTaps.last?.processObjectIDs, [201])

        model.selectApp(World.music)
        world.settle()
        XCTAssertEqual(world.audio.createdTaps.last?.processObjectIDs, [210])
        XCTAssertEqual(model.status.state, .running(.both))
    }

    func testChoosingNoAppMixesOnlyTheMicrophone() {
        world.launchDiscord()
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = World.discord
        let model = world.makeModel(settings: settings)
        model.start()
        model.selectApp(nil)
        world.settle()
        XCTAssertEqual(model.status.state, .running(.micOnly))
        XCTAssertEqual(model.statusLine.tone, .good)
    }

    func testChangingTheMicRebuildsTheEngineWithIt() {
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(model.status.micUID, "BuiltInMic")
        model.selectMic(.device(uid: "USB-Mic"))
        world.settle()
        XCTAssertEqual(model.status.micUID, "USB-Mic")
    }

    func testBufferSizeChangesRebuildAndOnlyOfferedSizesAreAccepted() {
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(world.audio.bufferSizes.last, 128)
        model.setBufferFrameSize(256)
        world.settle()
        XCTAssertEqual(world.audio.bufferSizes.last, 256)
        let builds = world.audio.createdAggregates.count
        model.setBufferFrameSize(100)
        world.settle()
        XCTAssertEqual(model.bufferFrameSize, 256)
        XCTAssertEqual(world.audio.createdAggregates.count, builds, "100 frames is not an offered size")
    }

    // MARK: The guide comes first

    func testNothingStartsBeforeTheGuideIsDone() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        XCTAssertEqual(world.audio.ioRunning, 0, "the microphone prompt belongs to the guide")
        XCTAssertEqual(model.statusLine.fix, .continueSetup)

        model.completeOnboarding()
        XCTAssertTrue(model.onboardingDone)
        XCTAssertEqual(world.audio.ioRunning, 1)
        XCTAssertTrue(world.makeSettings().onboardingDone)
    }

    func testPassingTheAppSoundScreenFinishesSetupAndStartsTheEngine() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        model.guideNext()
        model.guideNext()
        XCTAssertEqual(model.guide.step, .appSound)
        XCTAssertFalse(model.onboardingDone, "still on the screen that asks about the app's sound")
        XCTAssertEqual(world.audio.ioRunning, 0)

        model.guideNext()
        XCTAssertEqual(model.guide.step, .finish)
        XCTAssertTrue(model.onboardingDone, "both permission screens are behind us")
        XCTAssertEqual(world.audio.ioRunning, 1, "the engine runs, which is what makes macOS ask about the app")
        XCTAssertTrue(world.makeSettings().onboardingDone)
    }

    func testClosingTheGuideOnTheAppSoundScreenCountsAsDone() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        model.guideNext()
        model.guideNext()
        model.guideWindowClosed()
        XCTAssertTrue(model.onboardingDone)
        XCTAssertEqual(world.audio.ioRunning, 1)
        XCTAssertTrue(world.makeSettings().onboardingDone, "later launches start the engine")
    }

    func testClosingTheGuideOnTheLastScreenKeepsItDoneWithOneEngine() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        model.guideNext()
        model.guideNext()
        model.guideNext()
        model.guideWindowClosed()
        XCTAssertTrue(model.onboardingDone)
        XCTAssertEqual(world.audio.ioRunning, 1)
    }

    func testClosingTheGuideBeforeThePermissionScreensEndsDoesNotCount() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        model.guideNext()
        XCTAssertEqual(model.guide.step, .microphone)
        model.guideWindowClosed()
        XCTAssertFalse(model.onboardingDone)
        XCTAssertEqual(world.audio.ioRunning, 0)
    }

    func testShowingTheGuideAgainStartsAtTheFirstScreen() {
        let model = world.makeModel(onboardingDone: false)
        model.guideNext()
        model.guideNext()
        model.resetGuide()
        XCTAssertEqual(model.guide.step, .welcome)
    }

    func testBackGoesToThePreviousScreen() {
        let model = world.makeModel(onboardingDone: false)
        model.guideNext()
        model.guideBack()
        XCTAssertEqual(model.guide.step, .welcome)
    }

    // MARK: Permissions

    func testADeniedMicrophoneShowsTheFixThatOpensItsSettingsPane() {
        world.permissions.microphone = .denied
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(model.statusLine.tone, .problem)
        XCTAssertEqual(model.statusLine.fix, .openMicrophoneSettings)
        model.perform(.openMicrophoneSettings)
        XCTAssertEqual(world.openedURLs, [SettingsPane.microphone.url])
    }

    func testTheSystemAudioFixOpensItsOwnPane() {
        let model = world.makeModel()
        model.perform(.openSystemAudioSettings)
        XCTAssertEqual(world.openedURLs, [SettingsPane.systemAudioRecording.url])
        XCTAssertNotEqual(SettingsPane.microphone.url, SettingsPane.systemAudioRecording.url)
    }

    func testAllowingTheMicrophoneAsksAndRebuildsTheEngine() {
        world.permissions.microphone = .notDetermined
        world.permissions.answer = .granted
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(model.statusLine.fix, .allowMicrophone)
        let builds = world.audio.createdAggregates.count

        model.perform(.allowMicrophone)
        XCTAssertEqual(world.permissions.requests, 1)
        XCTAssertEqual(model.micPermission, .granted)
        world.settle()
        XCTAssertEqual(world.audio.createdAggregates.count, builds + 1, "the mic is opened again with permission")
        XCTAssertEqual(model.statusLine.tone, .good)
    }

    func testAPermissionGrantedInSystemSettingsIsNoticedWhenTheMenuOpens() {
        world.permissions.microphone = .denied
        let model = world.makeModel()
        model.start()
        let builds = world.audio.createdAggregates.count
        world.permissions.microphone = .granted
        model.menuDidOpen()
        world.settle()
        XCTAssertEqual(model.micPermission, .granted)
        XCTAssertEqual(world.audio.createdAggregates.count, builds + 1)
    }

    func testTryAgainRebuildsTheEngine() {
        let model = world.makeModel()
        model.start()
        let builds = world.audio.createdAggregates.count
        model.perform(.tryAgain)
        world.settle()
        XCTAssertEqual(world.audio.createdAggregates.count, builds + 1)
    }

    // MARK: Feedback loop

    func testTheFeedbackLoopWarningNamesTheApp() {
        world.launchDiscord()
        let settings = world.settingsOfAnEarlierLaunch()
        settings.appBundleID = World.discord
        let model = world.makeModel(settings: settings)
        model.start()
        XCTAssertNil(model.feedbackWarning)
        XCTAssertFalse(model.hasWarning)

        world.audio.inputClients = [101]
        world.audio.emit(.inputClientsChanged)
        XCTAssertEqual(model.feedbackWarning, "Discord is using Duette as its input: callers will hear themselves")
        XCTAssertTrue(model.hasWarning)
        XCTAssertEqual(model.status.state, .running(.both), "warn only: the audio is left alone")

        world.audio.inputClients = []
        world.audio.emit(.inputClientsChanged)
        XCTAssertNil(model.feedbackWarning)
    }

    // MARK: Launch at login

    func testLaunchAtLoginIsReadFromTheSystemEveryTime() {
        let model = world.makeModel()
        model.menuDidOpen()
        XCTAssertEqual(model.loginItem, .off)
        world.loginItem.state = .on
        model.menuDidOpen()
        XCTAssertEqual(model.loginItem, .on, "never cached: the user can change it in System Settings")
        XCTAssertNil(world.defaults.object(forKey: "launchAtLogin"))
    }

    func testTurningLaunchAtLoginOnAndOff() {
        let model = world.makeModel()
        model.setLaunchAtLogin(true)
        XCTAssertEqual(world.loginItem.calls, [true])
        XCTAssertEqual(model.loginItem, .on)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(world.loginItem.calls, [true, false])
        XCTAssertEqual(model.loginItem, .off)
        XCTAssertNil(model.message)
    }

    func testAFailedLaunchAtLoginChangeSaysSoInPlainWords() {
        world.loginItem.failing = true
        let model = world.makeModel()
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItem, .off)
        // macOS 15 calls the pane "Login Items & Extensions".
        XCTAssertEqual(model.message,
                       "Duette couldn't change this. You can also do it in System Settings > General > Login Items & Extensions.")
    }

    func testLoginItemsApprovalOpensTheLoginItemsSettings() {
        world.loginItem.state = .needsApproval
        let model = world.makeModel()
        model.menuDidOpen()
        XCTAssertEqual(model.loginItem, .needsApproval)
        model.perform(.openLoginItemsSettings)
        XCTAssertEqual(world.settingsPaneOpened, 1)
    }

    // MARK: Test tones

    func testTheDriverTestToneGoesThroughTheDriverProperty() {
        let model = world.makeModel()
        model.setDriverTone(true)
        XCTAssertEqual(world.driverToneCalls, [true])
        XCTAssertTrue(model.driverToneOn)
        model.setDriverTone(false)
        XCTAssertEqual(world.driverToneCalls, [true, false])
        XCTAssertFalse(model.driverToneOn)
    }

    func testAFailingDriverToneStaysOffAndSaysWhy() {
        world.driverToneFails = true
        let model = world.makeModel()
        model.setDriverTone(true)
        XCTAssertFalse(model.driverToneOn)
        XCTAssertNotNil(model.message)
    }

    func testTheEngineTestToneIsTheEnginesOwn() {
        let model = world.makeModel()
        model.setEngineTone(true)
        XCTAssertTrue(model.controller.engine.testTone)
        XCTAssertTrue(model.engineToneOn)
        model.setEngineTone(false)
        XCTAssertFalse(model.controller.engine.testTone)
    }

    func testTheDriverToneIsReadFromTheDriverAtStart() {
        world.driverToneIsOn = true
        let model = world.makeModel()
        model.start()
        XCTAssertTrue(model.driverToneOn, "it keeps beeping in the driver after Duette quits, so a new run must show it")
    }

    func testTheDriverToneIsReadAgainWhenTheMenuOpens() {
        let model = world.makeModel()
        model.start()
        XCTAssertFalse(model.driverToneOn)
        world.driverToneIsOn = true
        model.menuDidOpen()
        XCTAssertTrue(model.driverToneOn)
        world.driverToneIsOn = false
        model.menuDidOpen()
        XCTAssertFalse(model.driverToneOn)
    }

    func testWithoutADriverTheToneShowsOff() {
        world.driverToneIsOn = nil
        let model = world.makeModel()
        model.start()
        XCTAssertFalse(model.driverToneOn)
    }

    func testAFailedSwitchOffLeavesTheToneShownOn() {
        world.driverToneIsOn = true
        let model = world.makeModel()
        model.start()
        world.driverToneFails = true
        model.setDriverTone(false)
        XCTAssertTrue(model.driverToneOn, "the tone is still playing, so the switch must say so")
        XCTAssertNotNil(model.message)
    }

    func testQuittingSwitchesTheDriverToneOff() {
        world.driverToneIsOn = true
        let model = world.makeModel()
        model.start()
        model.stop()
        XCTAssertEqual(world.driverToneCalls, [false])
        XCTAssertEqual(world.driverToneIsOn, false)
    }

    func testQuittingWithTheToneOffLeavesTheDriverAlone() {
        let model = world.makeModel()
        model.start()
        model.stop()
        XCTAssertTrue(world.driverToneCalls.isEmpty)
    }

    // MARK: Export Diagnostics

    private func makeDestination(named name: String = "Duette-Diagnostics-test.zip") throws -> URL {
        let folder = world.scratch.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    func testExportAsksWhereToSaveSavesThereAndShowsTheFile() throws {
        let destination = try makeDestination()
        world.exportDestination = destination
        let model = world.makeModel()
        model.start()
        model.exportDiagnostics()
        XCTAssertEqual(model.export, .saved(destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(world.revealedURLs, [destination], "Finder shows the saved file")
        let suggested = try XCTUnwrap(world.suggestedNames.first)
        XCTAssertTrue(suggested.hasPrefix("Duette-Diagnostics-") && suggested.hasSuffix(".zip"))
        let left = try FileManager.default.contentsOfDirectory(atPath: world.scratch.path)
        XCTAssertEqual(left, ["chosen"], "no half-made files stay behind")
    }

    func testCancellingTheSavePanelSavesNothing() throws {
        world.exportDestination = nil
        let model = world.makeModel()
        model.start()
        model.exportDiagnostics()
        XCTAssertEqual(model.export, .idle)
        XCTAssertTrue(world.revealedURLs.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: world.scratch.path)) ?? []
        XCTAssertEqual(left, [])
    }

    func testAFailedZipShowsAPlainErrorAndNeverAsksWhereToSave() {
        world.zipFails = true
        let model = world.makeModel()
        model.start()
        model.exportDiagnostics()
        guard case .failed(let message) = model.export else { return XCTFail("expected a failure, got \(model.export)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("ditto"), "plain words, not program names")
        XCTAssertTrue(world.suggestedNames.isEmpty)
        XCTAssertTrue(world.revealedURLs.isEmpty)
    }

    func testAnUnwritablePlaceShowsAPlainError() {
        world.exportDestination = URL(fileURLWithPath: "/nonexistent-duette-folder/Duette-Diagnostics.zip")
        let model = world.makeModel()
        model.start()
        model.exportDiagnostics()
        guard case .failed(let message) = model.export else { return XCTFail("expected a failure, got \(model.export)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(world.revealedURLs.isEmpty)
    }

    func testChoosingAnExistingFileReplacesIt() throws {
        let destination = try makeDestination()
        try Data("old".utf8).write(to: destination)
        world.exportDestination = destination
        let model = world.makeModel()
        model.start()
        model.exportDiagnostics()
        XCTAssertEqual(model.export, .saved(destination))
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 3, "the new zip took the old file's place")
    }

    // MARK: Choices for the pickers

    func testThePickersListWhatCanBeChosen() {
        world.launchDiscord()
        world.launchMusic()
        let model = world.makeModel()
        model.menuDidOpen()
        XCTAssertEqual(Set(model.appChoices.map(\.bundleID)), [World.discord, World.music])
        XCTAssertTrue(model.appChoices.allSatisfy { $0.isPlayingAudio })
        XCTAssertEqual(model.micChoices.first?.selection, .systemDefault)
        XCTAssertFalse(model.micChoices.contains { $0.name == "Duette" }, "Duette is not offered as its own mic")
    }

    func testTheNameOfTheSelectedAppComesFromTheRunningAppOrTheBundleID() {
        world.launchDiscord()
        let model = world.makeModel()
        model.menuDidOpen()
        XCTAssertEqual(model.displayName(for: World.discord), "Discord")
        XCTAssertEqual(model.displayName(for: "com.example.Gone"), "Gone")
    }

    // MARK: Diagnostics

    func testThePermissionsInTheDiagnosticsSayWhatIsKnown() {
        world.permissions.microphone = .denied
        let model = world.makeModel()
        model.start()
        let permissions = model.diagnosticsPermissions()
        XCTAssertEqual(permissions["microphone"], "denied")
        XCTAssertNotNil(permissions["systemAudioRecording"])
    }

    // MARK: Measure latency

    private let measured = LoopbackMeasurement(bufferFrameSize: 128, meanFrames: 275, worstFrames: 400, sampleOffset: 0,
                                               confidence: 1, takes: 1)

    func testMeasuringTheLatencySaysInPlainWordsWhatDuetteAdds() {
        world.audio.loopback = .success(measured)
        let model = world.makeModel()
        model.start()
        XCTAssertEqual(model.latencyCheck, .idle)
        XCTAssertNil(model.latencyResult)

        model.measureLatency()

        guard case .done(let measurement) = model.latencyCheck else { return XCTFail("\(model.latencyCheck)") }
        // The fake HAL gives every device a 128-frame buffer and nothing else: 128 into the engine,
        // then the 275 frames measured through the sink. Duette's own part is those 275 (5.7 ms).
        XCTAssertEqual(measurement.totalFrames, 128 + 275)
        XCTAssertEqual(model.latencyResult, "Duette adds about 6 ms of delay.")
        XCTAssertEqual(model.latencyTotal, "Your microphone to other apps: about 8 ms.")
        XCTAssertEqual(model.latencyDetail, "Measured with a test sound: 5.7 ms (expected 5.3 ms).")
        XCTAssertEqual(world.audio.loopbackCalls.count, 1)
        XCTAssertEqual(world.audio.loopbackCalls.first?.ioRunning, 0, "the engine pauses while the test sound plays")
        XCTAssertEqual(world.audio.ioRunning, 1, "and runs again after")
        XCTAssertEqual(model.status.state, .running(.micOnly))
    }

    func testMeasuringBeforeDuetteRunsSaysWhy() {
        let model = world.makeModel(onboardingDone: false)
        model.start()
        model.measureLatency()
        XCTAssertEqual(model.latencyCheck, .failed("Duette isn't running yet, so there is nothing to measure."))
        XCTAssertEqual(model.latencyResult, "Duette isn't running yet, so there is nothing to measure.")
        XCTAssertNil(model.latencyTotal)
        XCTAssertNil(model.latencyDetail)
        XCTAssertTrue(world.audio.loopbackCalls.isEmpty)
    }

    func testATestSoundThatNeverArrivesPointsAtTheMicrophonePermission() {
        world.audio.loopback = .failure(LatencyMeasurementError.notHeard)
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        XCTAssertEqual(model.latencyCheck,
                       .failed("Duette couldn't hear its test sound. Check that Duette may use the microphone, then try again."))
        XCTAssertEqual(world.audio.ioRunning, 1)
    }

    func testAnyOtherFailureAsksToTryAgain() {
        world.audio.loopback = .failure(CoreAudioError(OSStatus(kAudioHardwareUnspecifiedError), "start recording from Duette"))
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        XCTAssertEqual(model.latencyCheck, .failed("The measurement didn't work. Please try again."))
    }

    func testTheMeasurementGoesIntoTheDiagnostics() {
        world.audio.loopback = .success(measured)
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        let report = DiagnosticsCollector(audioSystem: world.audio, controller: model.controller,
                                          timing: { _ in DeviceTiming(bufferFrameSize: 128) }, selfTestTone: { false })
            .collect(selfTests: model.selfTestResults)
        XCTAssertEqual(report.engine?.measuredLatency?.totalFrames, 128 + 275)
        XCTAssertEqual(report.selfTests["latency"], "Duette adds 5.73 ms (5.33 ms estimated); microphone to other apps 8.40 ms")
    }

    func testTheDriversTestToneIsOffWhileMeasuringAndComesBackAfter() {
        let world = self.world!
        world.audio.loopback = .success(measured)
        world.driverToneIsOn = true
        var toneDuringMeasurement: Bool?
        world.audio.onMeasure = { [unowned world] in toneDuringMeasurement = world.driverToneIsOn }
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        XCTAssertEqual(toneDuringMeasurement, false, "the beep would be measured instead of the loopback")
        XCTAssertEqual(world.driverToneIsOn, true)
        XCTAssertEqual(world.driverToneCalls, [false, true])
        XCTAssertTrue(model.driverToneOn)
    }

    func testWithTheToneOffTheDriverIsLeftAlone() {
        world.audio.loopback = .success(measured)
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        XCTAssertEqual(world.driverToneCalls, [])
    }

    func testMeasuringWhileDuetteRestartsSaysSo() {
        world.audio.loopback = .success(measured)
        let model = world.makeModel()
        model.start()
        model.setBufferFrameSize(256)
        model.measureLatency()
        XCTAssertEqual(model.latencyCheck, .failed("Duette is restarting. Try again in a moment."))
    }

    func testAnOldResultGoesWhenTheEngineChanges() {
        world.audio.loopback = .success(measured)
        let model = world.makeModel()
        model.start()
        model.measureLatency()
        XCTAssertNotNil(model.latencyTotal)
        model.selectMic(.device(uid: "USB-Mic"))
        XCTAssertEqual(model.latencyCheck, .idle, "another mic")
        world.settle()

        model.measureLatency()
        XCTAssertNotNil(model.latencyTotal)
        model.perform(.tryAgain)
        world.settle()
        XCTAssertEqual(model.latencyCheck, .idle, "a rebuild")

        world.audio.loopback = .failure(LatencyMeasurementError.notHeard)
        model.measureLatency()
        XCTAssertNotEqual(model.latencyCheck, .idle)
        model.setBufferFrameSize(64)
        XCTAssertEqual(model.latencyCheck, .idle, "a failure goes too")
    }

    func testTheNoteAboutWhatOthersHearIsPlain() {
        XCTAssertEqual(AppModel.latencyNote,
                       "While it measures, apps listening to Duette hear a short silence and a soft chirp or two.")
    }
}
