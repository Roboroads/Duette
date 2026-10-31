import ServiceManagement
import XCTest

final class LoginItemTests: XCTestCase {
    /// Before the first register() the system answers "not found" for the app itself. That is not
    /// a dead end: registering is what makes it known, so the switch has to stay usable.
    func testNotFoundCountsAsOffSoTheSwitchStaysUsable() {
        XCTAssertEqual(LoginItemState(status: .notFound), .off)
    }

    func testTheOtherStatusesMapOneToOne() {
        XCTAssertEqual(LoginItemState(status: .notRegistered), .off)
        XCTAssertEqual(LoginItemState(status: .enabled), .on)
        XCTAssertEqual(LoginItemState(status: .requiresApproval), .needsApproval)
    }
}
