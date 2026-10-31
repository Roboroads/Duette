import XCTest

final class MeterScaleTests: XCTestCase {
    func testSilenceIsEmptyAndFullScaleIsFull() {
        XCTAssertEqual(MeterScale.fraction(peak: 0), 0)
        XCTAssertEqual(MeterScale.fraction(peak: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(MeterScale.fraction(peak: 2), 1, "above full scale stays on the meter")
    }

    func testTheScaleRunsFromMinus60dBToFullScale() {
        XCTAssertEqual(MeterScale.fraction(peak: 0.001), 0, accuracy: 1e-6, "-60 dB is the bottom")
        XCTAssertEqual(MeterScale.fraction(peak: 0.0001), 0, "below the bottom is empty")
        XCTAssertEqual(MeterScale.fraction(peak: 0.0316228), 0.5, accuracy: 1e-3, "-30 dB is half way")
    }

    func testBadValuesAreEmpty() {
        XCTAssertEqual(MeterScale.fraction(peak: -1), 0)
        XCTAssertEqual(MeterScale.fraction(peak: .nan), 0)
        XCTAssertEqual(MeterScale.fraction(peak: .infinity), 0)
    }

    func testTheMeterJumpsUpAtOnceAndFallsBackSmoothly() {
        let meter = MeterFollower(fallPerSecond: 1)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(meter.update(peak: 1, at: start), 1, accuracy: 1e-6)
        XCTAssertEqual(meter.update(peak: 0, at: start.addingTimeInterval(0.25)), 0.75, accuracy: 1e-6)
        XCTAssertEqual(meter.update(peak: 0, at: start.addingTimeInterval(0.50)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(meter.update(peak: 1, at: start.addingTimeInterval(0.55)), 1, accuracy: 1e-6, "a new peak wins")
        XCTAssertEqual(meter.update(peak: 0, at: start.addingTimeInterval(5)), 0, "it never goes below empty")
    }

    func testAClockThatGoesBackwardsDoesNotMoveTheMeter() {
        let meter = MeterFollower(fallPerSecond: 1)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        _ = meter.update(peak: 1, at: start)
        XCTAssertEqual(meter.update(peak: 0, at: start.addingTimeInterval(-3)), 1, accuracy: 1e-6)
    }

    func testTheMeterColourFollowsTheLevel() {
        XCTAssertEqual(MeterScale.zone(fraction: 0.2), .normal)
        XCTAssertEqual(MeterScale.zone(fraction: 0.85), .loud)
        XCTAssertEqual(MeterScale.zone(fraction: 0.99), .clipping)
    }
}
