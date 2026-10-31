@testable import DuettectlCore
import XCTest

final class ReportTests: XCTestCase {
    func testPrintsAndAppendsOneLinePerCheck() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("duettectl-report-\(UUID().uuidString).tsv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reporter = Reporter(command: "loopback", reportPath: path)
        var printed: [String] = []
        reporter.output = { printed.append($0) }

        XCTAssertTrue(reporter.check("latency", true, "272 frames (5.67 ms)", detail: "buffer 128"))
        XCTAssertFalse(reporter.check("silence", false, "600 frames"))
        reporter.info("hal", "latency 0 | safety 16")
        reporter.skip("vpio", "not available")
        XCTAssertEqual(reporter.failures, 1)
        XCTAssertFalse(reporter.passed)

        XCTAssertEqual(printed, [
            "CHECK PASS loopback.latency: 272 frames (5.67 ms) | buffer 128",
            "CHECK FAIL loopback.silence: 600 frames",
            "CHECK INFO loopback.hal: latency 0 | safety 16",
            "CHECK SKIP loopback.vpio: not available",
        ])
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "loopback\tlatency\tPASS\t272 frames (5.67 ms)\tbuffer 128",
            "loopback\tsilence\tFAIL\t600 frames\t",
            "loopback\thal\tINFO\tlatency 0 / safety 16\t",
            "loopback\tvpio\tSKIP\tnot available\t",
        ])
    }

    func testSanitize() {
        XCTAssertEqual(Reporter.sanitize(" a\tb\nc|d \r"), "a b c/d")
    }

    func testFormat() {
        XCTAssertEqual(Format.frames(272, sampleRate: 48000), "272 frames (5.67 ms)")
        XCTAssertEqual(Format.db(-12.004), "-12.00 dBFS")
        XCTAssertEqual(Format.hz(440.004), "440.00 Hz")
    }
}
