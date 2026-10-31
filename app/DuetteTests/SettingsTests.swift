import DuetteAudio
import XCTest

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "duette-settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFirstRunHasTheDefaults() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.isFirstRun)
        XCTAssertEqual(settings.version, Settings.currentVersion)
        XCTAssertNil(settings.appBundleID)
        XCTAssertEqual(settings.mic, .systemDefault)
        for source in MixSource.allCases {
            XCTAssertEqual(settings.gain(source), 1, "\(source) starts at 100%")
            XCTAssertFalse(settings.isMuted(source))
        }
        XCTAssertEqual(settings.bufferFrameSize, 128)
        XCTAssertFalse(settings.onboardingDone)
    }

    func testOnlyTheFirstLaunchIsAFirstRun() {
        XCTAssertTrue(Settings(defaults: defaults).isFirstRun)
        XCTAssertFalse(Settings(defaults: defaults).isFirstRun)
    }

    func testValuesRoundTripThroughANewInstance() {
        let first = Settings(defaults: defaults)
        first.appBundleID = "com.apple.Music"
        first.mic = .device(uid: "USB-Mic")
        first.setGain(0.5, for: .app)
        first.setGain(1.5, for: .mic)
        first.setMuted(true, for: .mic)
        first.bufferFrameSize = 256
        first.onboardingDone = true

        let second = Settings(defaults: defaults)
        XCTAssertEqual(second.appBundleID, "com.apple.Music")
        XCTAssertEqual(second.mic, .device(uid: "USB-Mic"))
        XCTAssertEqual(second.gain(.app), 0.5)
        XCTAssertEqual(second.gain(.mic), 1.5)
        XCTAssertEqual(second.gain(.output), 1)
        XCTAssertFalse(second.isMuted(.app))
        XCTAssertTrue(second.isMuted(.mic))
        XCTAssertEqual(second.bufferFrameSize, 256)
        XCTAssertTrue(second.onboardingDone)
    }

    func testClearingTheAppAndTheMicGoesBackToTheDefaults() {
        let settings = Settings(defaults: defaults)
        settings.appBundleID = "com.apple.Music"
        settings.mic = .device(uid: "USB-Mic")
        settings.appBundleID = nil
        settings.mic = .systemDefault
        XCTAssertNil(Settings(defaults: defaults).appBundleID)
        XCTAssertEqual(Settings(defaults: defaults).mic, .systemDefault)
    }

    func testGainsAreClampedToZeroToTwo() {
        let settings = Settings(defaults: defaults)
        settings.setGain(5, for: .app)
        XCTAssertEqual(settings.gain(.app), 2)
        settings.setGain(-3, for: .app)
        XCTAssertEqual(settings.gain(.app), 0)
        settings.setGain(.nan, for: .app)
        XCTAssertEqual(settings.gain(.app), 1, "a gain that is not a number falls back to 100%")
        settings.setGain(.infinity, for: .app)
        XCTAssertEqual(settings.gain(.app), 1)
        XCTAssertEqual(Settings.clampGain(0.25), 0.25)
    }

    func testAStoredGainOutOfRangeOrOfTheWrongTypeIsRepaired() {
        defaults.set(40, forKey: "gain.app")
        defaults.set("loud", forKey: "gain.mic")
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.gain(.app), 2)
        XCTAssertEqual(settings.gain(.mic), 1)
    }

    func testOnlyTheOfferedBufferSizesAreAccepted() {
        let settings = Settings(defaults: defaults)
        settings.bufferFrameSize = 100
        XCTAssertEqual(settings.bufferFrameSize, 128, "100 is not an offered size, so nothing changes")
        for size in EngineConfiguration.bufferFrameSizes {
            settings.bufferFrameSize = size
            XCTAssertEqual(settings.bufferFrameSize, size)
        }
        defaults.set(77, forKey: "bufferFrameSize")
        XCTAssertEqual(settings.bufferFrameSize, 128, "a stored size that is not offered reads as the default")
    }

    func testAnOlderVersionIsMigratedStepByStep() {
        defaults.set(1, forKey: "settingsVersion")
        defaults.set("com.apple.Music", forKey: "legacyApp")
        var steps: [Int] = []
        let settings = Settings(defaults: defaults, currentVersion: 3, migrations: [
            1: { defaults in
                steps.append(1)
                if let legacy = defaults.string(forKey: "legacyApp") {
                    defaults.set(legacy, forKey: "appBundleID")
                    defaults.removeObject(forKey: "legacyApp")
                }
            },
            2: { _ in steps.append(2) },
        ])
        XCTAssertFalse(settings.isFirstRun)
        XCTAssertEqual(steps, [1, 2])
        XCTAssertEqual(settings.version, 3)
        XCTAssertEqual(settings.appBundleID, "com.apple.Music")
        XCTAssertNil(defaults.string(forKey: "legacyApp"))

        _ = Settings(defaults: defaults, currentVersion: 3, migrations: [1: { _ in steps.append(99) }])
        XCTAssertEqual(steps, [1, 2], "a migration runs once")
    }

    func testSettingsFromANewerVersionAreLeftAlone() {
        defaults.set(9, forKey: "settingsVersion")
        defaults.set("com.apple.Music", forKey: "appBundleID")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.isFirstRun)
        XCTAssertEqual(settings.version, 9)
        XCTAssertEqual(settings.appBundleID, "com.apple.Music")
    }
}
