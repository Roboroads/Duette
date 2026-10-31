@testable import DuetteAudio
import XCTest

final class CaptureAuthorizationTests: XCTestCase {
    func testOnlyAnExactAnswerOfAllowedOrDeniedCounts() {
        XCTAssertEqual(TCCPreflight.authorization(forResult: 0), .authorized)
        XCTAssertEqual(TCCPreflight.authorization(forResult: 1), .denied)
        XCTAssertEqual(TCCPreflight.authorization(forResult: 2), .unknown, "not asked yet")
        XCTAssertEqual(TCCPreflight.authorization(forResult: -1), .unknown)
        XCTAssertEqual(TCCPreflight.authorization(forResult: nil), .unknown, "the framework or function is missing")
    }

    func testAskingTheRealSystemNeverCrashes() {
        // Whatever this machine says (a CI runner has no answer worth checking), it must be one of the three.
        let answer = CoreAudioSystem().systemAudioCaptureAuthorization()
        XCTAssertTrue([CaptureAuthorization.authorized, .denied, .unknown].contains(answer))
    }
}
