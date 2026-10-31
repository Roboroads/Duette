import CoreAudio
import DuetteAudio
import XCTest

final class StatusLineTests: XCTestCase {
    private let discord = "com.hnc.Discord"

    private func line(_ state: EngineState, sources: EngineSources = .none, appName: String? = "Discord",
                      micPermission: PermissionState = .granted, setupDone: Bool = true,
                      silent: Bool = false, tapFailed: Bool = false) -> StatusLine {
        var status = EngineStatus()
        status.state = state
        status.sources = sources
        status.appSilentWhilePlaying = silent
        if tapFailed { status.tapError = CoreAudioError(-1, "create the app's tap") }
        return StatusLine.make(status: status, selectedAppName: appName, micPermission: micPermission,
                               setupDone: setupDone)
    }

    func testWorkingIsGreenAndSaysWhatItMeans() {
        let result = line(.running(.both), sources: .both)
        XCTAssertEqual(result.tone, .good)
        XCTAssertEqual(result.message, "Working: other apps can use Duette as a microphone")
        XCTAssertNil(result.fix)
    }

    func testMicOnlyWithoutAnAppIsWorking() {
        let result = line(.running(.micOnly), sources: .micOnly, appName: nil)
        XCTAssertEqual(result.tone, .good)
    }

    func testWaitingForTheAppIsOrangeAndNamesTheApp() {
        let result = line(.waitingForApp(bundleID: discord), sources: .micOnly)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.message, "Waiting for Discord to start")
        XCTAssertNil(result.fix)
    }

    func testWaitingForAnAppWithoutAKnownNameUsesTheEndOfItsBundleID() {
        let result = line(.waitingForApp(bundleID: "com.example.Gone"), sources: .micOnly, appName: nil)
        XCTAssertEqual(result.message, "Waiting for Gone to start")
    }

    func testMissingDriverIsRedAndPointsAtTheInstaller() {
        let result = line(.waitingForDriver)
        XCTAssertEqual(result.tone, .problem)
        XCTAssertEqual(result.message, "Duette isn't installed properly. Please run the Duette installer again.")
        XCTAssertNil(result.fix)
    }

    func testAnEngineErrorOffersTryAgainAndShowsNoCode() {
        let result = line(.error(status: -10851, attempt: 2))
        XCTAssertEqual(result.tone, .problem)
        XCTAssertEqual(result.fix, .tryAgain)
        XCTAssertFalse(result.message.contains("10851"), "error codes go to the diagnostics, not the menu")
        XCTAssertFalse(result.message.lowercased().contains("error"))
    }

    func testADeniedMicrophoneOffersTheMicrophoneSettings() {
        let result = line(.running(.appOnly), sources: .appOnly, micPermission: .denied)
        XCTAssertEqual(result.tone, .problem)
        XCTAssertEqual(result.message, "Duette needs permission to use your microphone")
        XCTAssertEqual(result.fix, .openMicrophoneSettings)
    }

    func testAnUnansweredMicrophoneQuestionOffersToAskIt() {
        let result = line(.running(.micOnly), sources: .micOnly, micPermission: .notDetermined)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.fix, .allowMicrophone)
    }

    func testSilenceFromAPlayingAppMeansTheAppSoundPermissionIsOff() {
        let result = line(.running(.both), sources: .both, silent: true)
        XCTAssertEqual(result.tone, .problem)
        XCTAssertEqual(result.message, "Duette needs permission to hear Discord")
        XCTAssertEqual(result.fix, .openSystemAudioSettings)
    }

    func testAMissingMicrophoneIsOrange() {
        let result = line(.running(.appOnly), sources: .appOnly)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.message, "Your microphone isn't connected")
    }

    func testNothingToMixIsOrange() {
        let result = line(.running(.none), sources: .none, appName: nil)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.message, "Your microphone isn't connected")
    }

    func testAnAppThatCannotBeHeardYetOffersTryAgain() {
        let result = line(.running(.micOnly), sources: .micOnly, tapFailed: true)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.message, "Duette can't hear Discord yet")
        XCTAssertEqual(result.fix, .tryAgain)
    }

    func testUnfinishedSetupComesFirst() {
        let result = line(.idle, setupDone: false)
        XCTAssertEqual(result.tone, .waiting)
        XCTAssertEqual(result.fix, .continueSetup)
    }

    func testPausedIsGrey() {
        let result = line(.idle)
        XCTAssertEqual(result.tone, .idle)
        XCTAssertEqual(result.message, "Duette is paused")
    }

    func testAMissingDriverBeatsADeniedMicrophone() {
        let result = line(.waitingForDriver, micPermission: .denied)
        XCTAssertEqual(result.message, "Duette isn't installed properly. Please run the Duette installer again.")
    }

    func testEveryFixHasAShortPlainTitle() {
        for fix in FixAction.allCases {
            XCTAssertFalse(fix.title.isEmpty)
            XCTAssertLessThanOrEqual(fix.title.count, 30, "\(fix) is a button label, not a sentence")
        }
    }

    /// The plan's rule for the main view: plain words only (S7). Codes go to the diagnostics.
    func testNoTechnicalWordsInAnythingTheStatusLineCanSay() {
        let banned = ["tap", "aggregate", "buffer", "ioproc", "hal", "osstatus"]
        var messages: [String] = []
        let states: [EngineState] = [
            .idle, .waitingForDriver, .waitingForApp(bundleID: discord), .running(.both), .running(.micOnly),
            .running(.appOnly), .running(.none), .error(status: -50, attempt: 1),
        ]
        for state in states {
            for permission in [PermissionState.granted, .denied, .notDetermined] {
                for silent in [false, true] {
                    for setupDone in [false, true] {
                        let result = line(state, micPermission: permission, setupDone: setupDone, silent: silent)
                        messages.append(result.message)
                        if let fix = result.fix { messages.append(fix.title) }
                    }
                }
            }
        }
        messages.append(line(.running(.micOnly), tapFailed: true).message)
        for message in Set(messages) {
            let words = message.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in banned {
                XCTAssertFalse(words.contains(word), "'\(message)' uses the word '\(word)'")
            }
        }
    }

    func testBundleIDNamesFallBackToTheLastPart() {
        XCTAssertEqual(AppNaming.fallbackName("com.hnc.Discord"), "Discord")
        XCTAssertEqual(AppNaming.fallbackName("Discord"), "Discord")
        XCTAssertEqual(AppNaming.fallbackName(""), "that app")
    }
}
