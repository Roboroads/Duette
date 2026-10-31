@testable import DuettectlCore
import XCTest

final class SoakPlanTests: XCTestCase {
    private let desktop = "/Users/tester/Desktop"

    private func plan(_ values: [String: String] = [:], flags: Set<String> = [], buffer: UInt32 = 128) throws -> SoakPlan {
        var all = ["minutes": "10"]
        all.merge(values) { $1 }
        return try SoakPlan(Invocation(command: "soak", values: all, flags: flags), defaultBuffer: buffer,
                            desktop: desktop, now: Date(timeIntervalSince1970: 0))
    }

    // MARK: Options

    func testCIRunsTheTestMicAtTheGlobalBuffer() throws {
        let soak = try plan(buffer: 64)
        XCTAssertFalse(soak.real)
        XCTAssertEqual(soak.minutes, 10)
        XCTAssertEqual(soak.buffers, [64])
        XCTAssertEqual(soak.mic, .testMic)
        XCTAssertNil(soak.app)
        XCTAssertFalse(soak.withApp)
        XCTAssertNil(soak.outPath)
        XCTAssertEqual(soak.controlSeconds, 0)
        XCTAssertEqual(soak.checkPrefix(for: 64), "", "one buffer size keeps the check names integration.sh reads")
    }

    func testHandsOnIsTheWholeRunForATestersMac() throws {
        let soak = try plan(flags: ["hands-on"])
        XCTAssertTrue(soak.real, "a shipped driver has no test devices: the real mic is the signal")
        XCTAssertEqual(soak.mic, .systemDefault)
        XCTAssertNil(soak.app)
        XCTAssertEqual(soak.buffers, [128, 64])
        let out = try XCTUnwrap(soak.outPath)
        XCTAssertTrue(out.hasPrefix(desktop + "/Duette-soak-"), out)
        XCTAssertTrue(out.hasSuffix(".txt"), out)
        XCTAssertEqual(soak.controlSeconds, 30)
        XCTAssertEqual(soak.checkPrefix(for: 128), "128.")
        XCTAssertEqual(soak.checkPrefix(for: 64), "64.")
        XCTAssertEqual(soak.watchdogSeconds, 30 + 2 * (600 + 120) + 60)
    }

    func testHandsOnOptionsCanBeOverridden() throws {
        let soak = try plan(["minutes": "0.25", "buffers": "256", "mic": "BuiltInMicrophoneDevice",
                             "app": "com.hnc.Discord", "out": "/tmp/soak.txt"], flags: ["hands-on"])
        XCTAssertTrue(soak.real)
        XCTAssertEqual(soak.minutes, 0.25)
        XCTAssertEqual(soak.buffers, [256])
        XCTAssertEqual(soak.mic, .uid("BuiltInMicrophoneDevice"))
        XCTAssertEqual(soak.app, "com.hnc.Discord")
        XCTAssertEqual(soak.outPath, "/tmp/soak.txt")
    }

    func testARealMicOrAnAppMeansARealSoak() throws {
        let mic = try plan(["mic": "default"])
        XCTAssertTrue(mic.real)
        XCTAssertEqual(mic.mic, .systemDefault)
        XCTAssertEqual(mic.buffers, [128])
        XCTAssertNil(mic.outPath)
        XCTAssertEqual(mic.controlSeconds, 0)
        let app = try plan(["app": "com.hnc.Discord"])
        XCTAssertTrue(app.real)
        XCTAssertEqual(app.mic, .systemDefault)
        XCTAssertFalse(try plan(["mic": "test-mic"]).real)
    }

    func testBufferLists() throws {
        XCTAssertEqual(try SoakPlan.parseBuffers("128,64"), [128, 64])
        XCTAssertEqual(try SoakPlan.parseBuffers(" 512 , 256 "), [512, 256])
        for bad in ["", "128,", "abc", "8", "128,-1", "70000"] {
            XCTAssertThrowsError(try SoakPlan.parseBuffers(bad), bad)
        }
    }

    func testImpossiblePlansAreRefused() {
        XCTAssertThrowsError(try plan(["mic": "default"], flags: ["with-app"]), "--with-app plays into the CI test speaker")
        XCTAssertThrowsError(try plan(["minutes": "0"]))
        XCTAssertThrowsError(try plan(["buffers": "fast"]))
    }

    // MARK: Measuring

    func testWindowsWithSoundAndAGapAreDropouts() {
        XCTAssertEqual(SoakPlan.classify(peak: 0.2, longestZeroRun: 0), .sound)
        XCTAssertEqual(SoakPlan.classify(peak: 0.2, longestZeroRun: 31), .sound)
        XCTAssertEqual(SoakPlan.classify(peak: 0.2, longestZeroRun: 32), .dropout)
        XCTAssertEqual(SoakPlan.classify(peak: 0, longestZeroRun: 48000), .silent, "nothing came in at all: not a gap")
    }

    func testOverloadsAreCountedPerMinute() {
        XCTAssertEqual(SoakPlan.perMinute([1, 59.9, 60, 61, 179, 400], minutes: 3), [2, 2, 1])
        XCTAssertEqual(SoakPlan.perMinute([], minutes: 2.5), [0, 0, 0])
        XCTAssertEqual(SoakPlan.perMinute([-1, 5], minutes: 1), [1])
    }

    func testDriftComesFromTheTwoClocks() throws {
        let sink = try XCTUnwrap(Drift.rate(from: ClockReading(sampleTime: 1_000, nanos: 0),
                                            to: ClockReading(sampleTime: 1_000 + 48_000 * 60, nanos: 60e9)))
        XCTAssertEqual(sink, 48_000, accuracy: 1e-6)
        // The CI test mic runs 200 ppm fast.
        let mic = try XCTUnwrap(Drift.rate(from: ClockReading(sampleTime: 0, nanos: 0),
                                           to: ClockReading(sampleTime: 48_009.6 * 60, nanos: 60e9)))
        XCTAssertEqual(try XCTUnwrap(Drift.ppm(mic: mic, sink: sink)), 200, accuracy: 1e-6)
        XCTAssertNil(Drift.rate(from: ClockReading(sampleTime: 0, nanos: 5), to: ClockReading(sampleTime: 10, nanos: 5)))
        XCTAssertNil(Drift.ppm(mic: 48_000, sink: 0))
    }

    // MARK: The result

    func testTheVerdictLine() throws {
        let soak = try plan(flags: ["hands-on"])
        let pass = [Check(command: "soak", name: "128.windows", status: .pass, value: "0 of 600 failed"),
                    Check(command: "soak", name: "control.default-output", status: .info, value: "0 in 30 s")]
        XCTAssertEqual(soak.verdict(pass), "SOAK PASS: 10 min at 128 and 64 frames each: no dropouts, no missed deadlines")
        let fail = pass + [Check(command: "soak", name: "64.overloads", status: .fail, value: "3"),
                           Check(command: "soak", name: "64.dropouts", status: .fail, value: "longest zero run 200 frames")]
        XCTAssertEqual(soak.verdict(fail), "SOAK FAIL: 64.overloads: 3")
        let skipped = [Check(command: "soak", name: "test-devices", status: .skip, value: "not found")]
        XCTAssertEqual(try plan().verdict(skipped), "SOAK SKIPPED: test-devices: not found")
        XCTAssertEqual(try plan().verdict([]), "SOAK FAIL: nothing was checked")
    }

    func testTheResultFileHasTheVerdictTheHeaderAndEveryCheck() throws {
        let soak = try plan(flags: ["hands-on"])
        let checks = [Check(command: "soak", name: "128.windows", status: .pass, value: "0 of 600 failed", detail: "dropouts")]
        let text = soak.report(header: ["macOS 15.1", "Mac14,2"], checks: checks, notes: ["overload at 12.3 s"])
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, soak.verdict(checks))
        XCTAssertTrue(lines.contains("macOS 15.1"))
        XCTAssertTrue(lines.contains("CHECK PASS soak.128.windows: 0 of 600 failed | dropouts"))
        XCTAssertTrue(lines.contains("overload at 12.3 s"))
    }
}
