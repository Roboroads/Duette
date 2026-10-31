@testable import DuetteAudio
import Foundation
import XCTest

final class CaptureAuthorizationTests: XCTestCase {
    private func macOS(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    func testOnlyAnExactAnswerOfAllowedOrDeniedCounts() {
        XCTAssertEqual(TCCPreflight.authorization(forResult: 0), .authorized)
        XCTAssertEqual(TCCPreflight.authorization(forResult: 1), .denied)
        XCTAssertEqual(TCCPreflight.authorization(forResult: 2), .unknown, "not asked yet")
        XCTAssertEqual(TCCPreflight.authorization(forResult: -1), .unknown)
        XCTAssertEqual(TCCPreflight.authorization(forResult: nil), .unknown, "the framework or function is missing")
    }

    func testBeforeMacOS14_4TheAnswerIsNotAskedForNorUsed() {
        for version in [macOS(14, 2), macOS(14, 3, 1), macOS(13, 6)] {
            var asked = 0
            let answer = TCCPreflight.audioCapture(osVersion: version) { _ in
                asked += 1
                return 1
            }
            XCTAssertEqual(answer, .unknown, "\(version): the mapping is only known from 14.4")
            XCTAssertEqual(asked, 0, "\(version)")
            XCTAssertNil(TCCPreflight.rawAudioCaptureAnswer(osVersion: version) { _ in 1 })
        }
    }

    func testFromMacOS14_4TheAnswerIsAskedForAndMapped() {
        for version in [macOS(14, 4), macOS(14, 7, 2), macOS(15, 0), macOS(26, 0)] {
            XCTAssertEqual(TCCPreflight.audioCapture(osVersion: version) { service in
                XCTAssertEqual(service, "kTCCServiceAudioCapture")
                return 0
            }, .authorized, "\(version)")
            XCTAssertEqual(TCCPreflight.audioCapture(osVersion: version) { _ in 1 }, .denied, "\(version)")
            XCTAssertEqual(TCCPreflight.audioCapture(osVersion: version) { _ in 2 }, .unknown, "\(version)")
            XCTAssertEqual(TCCPreflight.rawAudioCaptureAnswer(osVersion: version) { _ in 2 }, 2, "\(version)")
        }
    }

    func testAskingTheRealSystemNeverCrashes() {
        // Whatever this machine says (a CI runner has no answer worth checking), it must be one of the three.
        let system = CoreAudioSystem()
        XCTAssertTrue([CaptureAuthorization.authorized, .denied, .unknown].contains(system.systemAudioCaptureAuthorization()))
        _ = system.systemAudioCaptureRawAnswer()
    }
}
