import XCTest

final class SingleInstanceTests: XCTestCase {
    func testNoOtherCopyMeansWeStayAndNobodyIsActivated() {
        var activated: [pid_t] = []
        let guardian = SingleInstanceGuard(otherInstancePIDs: { [] }, activate: { activated.append($0) })
        XCTAssertFalse(guardian.yieldToRunningInstance())
        XCTAssertTrue(activated.isEmpty)
    }

    func testAnotherCopyIsActivatedAndWeQuit() {
        var activated: [pid_t] = []
        let guardian = SingleInstanceGuard(otherInstancePIDs: { [501] }, activate: { activated.append($0) })
        XCTAssertTrue(guardian.yieldToRunningInstance())
        XCTAssertEqual(activated, [501])
    }

    func testOnlyTheFirstOtherCopyIsActivated() {
        var activated: [pid_t] = []
        let guardian = SingleInstanceGuard(otherInstancePIDs: { [501, 502] }, activate: { activated.append($0) })
        XCTAssertTrue(guardian.yieldToRunningInstance())
        XCTAssertEqual(activated, [501])
    }

    // MARK: Which copies count

    private func instance(_ pid: pid_t, launched seconds: TimeInterval?, terminated: Bool = false) -> RunningInstance {
        RunningInstance(pid: pid, launchDate: seconds.map { Date(timeIntervalSinceReferenceDate: $0) },
                        isTerminated: terminated)
    }

    func testOwnProcessAndFinishedProcessesAreIgnored() {
        let all = [instance(10, launched: 5), instance(11, launched: 1, terminated: true)]
        XCTAssertEqual(SingleInstanceGuard.olderInstances(among: all, ownPID: 10), [])
    }

    func testOnlyCopiesThatStartedBeforeUsCount() {
        let all = [instance(10, launched: 5), instance(11, launched: 1), instance(12, launched: 9)]
        XCTAssertEqual(SingleInstanceGuard.olderInstances(among: all, ownPID: 10), [11],
                       "the newer copy (12) will quit itself, so we must not quit as well")
        XCTAssertEqual(SingleInstanceGuard.olderInstances(among: all, ownPID: 12), [10, 11])
        XCTAssertEqual(SingleInstanceGuard.olderInstances(among: all, ownPID: 11), [])
    }

    func testTwoCopiesStartedTogetherLeaveExactlyOne() {
        let all = [instance(20, launched: 5), instance(21, launched: 5)]
        let first = SingleInstanceGuard.olderInstances(among: all, ownPID: 20)
        let second = SingleInstanceGuard.olderInstances(among: all, ownPID: 21)
        XCTAssertEqual(first.count + second.count, 1, "the lower process ID stays")
        XCTAssertEqual(second, [20])
    }

    func testACopyWithoutALaunchDateCountsAsOlder() {
        let all = [instance(10, launched: 5), instance(11, launched: nil)]
        XCTAssertEqual(SingleInstanceGuard.olderInstances(among: all, ownPID: 10), [11])
    }
}
