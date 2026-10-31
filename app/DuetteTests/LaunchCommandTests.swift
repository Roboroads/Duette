import XCTest

final class LaunchCommandTests: XCTestCase {
    private var said: [String] = []

    private func run(_ item: LoginItemControlling) -> Int32 {
        LaunchCommand.unregisterLoginItem.run(loginItem: item) { self.said.append($0) }
    }

    func testTheUninstallerFlagIsFoundAfterTheProgramName() {
        let path = "/Applications/Duette.app/Contents/MacOS/Duette"
        XCTAssertEqual(LaunchCommand(arguments: [path, "--unregister-login-item"]), .unregisterLoginItem)
        XCTAssertNil(LaunchCommand(arguments: [path]))
        XCTAssertNil(LaunchCommand(arguments: [path, "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(LaunchCommand(arguments: ["--unregister-login-item"]), "the first argument is the program")
        XCTAssertNil(LaunchCommand(arguments: []))
    }

    func testARegisteredLoginItemIsRemoved() {
        let item = FakeLoginItem()
        item.state = .on
        XCTAssertEqual(run(item), 0)
        XCTAssertEqual(item.calls, [false])
        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(said, ["Removed Duette from Login Items."])
    }

    func testOneThatNeedsApprovalIsRemovedToo() {
        let item = FakeLoginItem()
        item.state = .needsApproval
        XCTAssertEqual(run(item), 0)
        XCTAssertEqual(item.calls, [false], "switched off in System Settings, but still in the list")
    }

    func testNothingToRemoveIsFine() {
        let item = FakeLoginItem()
        item.state = .off
        XCTAssertEqual(run(item), 0)
        XCTAssertEqual(item.calls, [], "unregistering what was never registered only makes an error")
        XCTAssertEqual(said, ["Duette is not in Login Items."])
    }

    func testARefusalIsAFailureTheUninstallerCanSee() {
        let item = FakeLoginItem()
        item.state = .on
        item.failing = true
        XCTAssertEqual(run(item), 1)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("Duette could not be removed from Login Items"))
    }

    func testAnErrorAfterItIsAlreadyGoneIsNotAFailure() {
        final class Racing: LoginItemControlling {
            struct Failure: Error {}
            var reads = 0
            var state: LoginItemState {
                reads += 1
                return reads == 1 ? .on : .off
            }
            func setEnabled(_ enabled: Bool) throws { throw Failure() }
        }
        XCTAssertEqual(run(Racing()), 0)
    }
}
