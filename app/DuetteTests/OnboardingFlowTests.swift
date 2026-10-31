import XCTest

final class OnboardingFlowTests: XCTestCase {
    func testTheGuideIsThreeScreensAndAFinalOne() {
        XCTAssertEqual(OnboardingFlow.Step.allCases, [.welcome, .microphone, .appSound, .finish])
    }

    func testNextWalksThroughTheScreensAndStopsAtTheEnd() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertEqual(flow.position, 1)
        flow.next()
        XCTAssertEqual(flow.step, .microphone)
        flow.next()
        XCTAssertEqual(flow.step, .appSound)
        flow.next()
        XCTAssertEqual(flow.step, .finish)
        XCTAssertTrue(flow.isLast)
        flow.next()
        XCTAssertEqual(flow.step, .finish, "there is nothing after the last screen")
        XCTAssertEqual(flow.position, 4)
        XCTAssertEqual(flow.count, 4)
    }

    func testBackStopsAtTheFirstScreen() {
        var flow = OnboardingFlow(step: .appSound)
        flow.back()
        XCTAssertEqual(flow.step, .microphone)
        flow.back()
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    func testTheMicrophoneScreenOffersTheRightButton() {
        XCTAssertEqual(OnboardingFlow.microphoneButton(for: .notDetermined), .allow)
        XCTAssertEqual(OnboardingFlow.microphoneButton(for: .granted), .next)
        XCTAssertEqual(OnboardingFlow.microphoneButton(for: .denied), .openSettings)
    }

    func testEveryScreenHasOneBigButtonWithPlainWords() {
        let banned = ["tap", "aggregate", "buffer", "ioproc", "hal", "driver", "osstatus"]
        for step in OnboardingFlow.Step.allCases {
            let text = OnboardingText.text(for: step, appName: "Discord")
            XCTAssertFalse(text.title.isEmpty)
            XCTAssertFalse(text.body.isEmpty)
            XCTAssertFalse(text.button.isEmpty)
            let all = (text.title + " " + text.body + " " + text.button).lowercased()
            let words = all.split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in banned {
                XCTAssertFalse(words.contains(word), "\(step) uses the word '\(word)'")
            }
        }
    }

    func testTheLastScreenTellsThemToPickDuetteInTheirOtherApp() {
        let text = OnboardingText.text(for: .finish, appName: nil)
        XCTAssertTrue(text.title.contains("Duette"))
        XCTAssertTrue(text.title.contains("OBS") && text.title.contains("Zoom"))
    }

    func testTheAppSoundScreenNamesTheChosenApp() {
        XCTAssertTrue(OnboardingText.text(for: .appSound, appName: "Discord").body.contains("Discord"))
        XCTAssertFalse(OnboardingText.text(for: .appSound, appName: nil).body.isEmpty)
    }
}
