import DuetteAudio
import XCTest

/// Proves that the test bundle builds, links DuetteKit and runs. Replaced by the real tests.
final class ScaffoldTests: XCTestCase {
    func testDuetteKitIsLinked() {
        XCTAssertEqual(DuetteDriver.sinkUID, "me.roboroads.duette.sink")
    }
}
