import XCTest

final class DiagnosticsExporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("duette-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var scratch: URL { root.appendingPathComponent("scratch") }

    private func makeExporter(
        scratch: URL? = nil,
        makeZip: @escaping (URL, URL) -> Bool = DiagnosticsExporter.zipWithDitto
    ) -> DiagnosticsExporter {
        DiagnosticsExporter(
            scratch: scratch ?? self.scratch,
            appPath: "/Applications/Duette.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/Duette.driver",
            appLog: { "app log line" },
            runCommand: { path, args in "output of \(path) \(args.joined(separator: " "))" },
            makeZip: makeZip)
    }

    private var date: Date { Date(timeIntervalSince1970: 1_793_000_000) } // 2026-10-26 07:33:20 UTC
    private let utc = TimeZone(identifier: "UTC")!

    func testTheFileNameHasTheTimestamp() {
        XCTAssertEqual(DiagnosticsExporter.baseName(for: date, timeZone: utc), "Duette-Diagnostics-2026-10-26-073320")
    }

    func testTheZipHoldsEveryFileThePlanLists() throws {
        let zip = try makeExporter().build(report: Data("{\"ok\":true}".utf8), now: date, timeZone: utc)
        XCTAssertEqual(zip.lastPathComponent, "Duette-Diagnostics-2026-10-26-073320.zip")
        XCTAssertEqual(zip.deletingLastPathComponent().path, scratch.path, "it is built in the scratch folder, not saved anywhere")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [zip.lastPathComponent],
                       "the folder it was zipped from is cleaned up")

        let unpacked = root.appendingPathComponent("unpacked")
        _ = CommandRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let folder = unpacked.appendingPathComponent("Duette-Diagnostics-2026-10-26-073320")
        func text(_ name: String) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(try text("diagnostics.json"), "{\"ok\":true}")
        XCTAssertEqual(try text("app.log"), "app log line")
        let system = try text("system.log")
        XCTAssertTrue(system.contains("/usr/bin/log"), "the system log comes from `log show`")
        XCTAssertTrue(system.contains("me.roboroads.duette"), "and is limited to Duette's subsystems")
        let signatures = try text("signatures.txt")
        XCTAssertTrue(signatures.contains("/usr/bin/codesign"))
        XCTAssertTrue(signatures.contains("/usr/sbin/spctl"))
        XCTAssertTrue(signatures.contains("/Applications/Duette.app"))
        XCTAssertTrue(signatures.contains("Duette.driver"))
    }

    func testAZipThatFailsIsAnError() {
        let exporter = makeExporter(makeZip: { _, _ in false })
        XCTAssertThrowsError(try exporter.build(report: Data("{}".utf8), now: date, timeZone: utc)) { error in
            XCTAssertEqual(error as? ExportError, .couldNotZip)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertEqual(left, [], "nothing is left behind")
    }

    func testAZipThatWasNeverWrittenIsAnErrorToo() {
        let exporter = makeExporter(makeZip: { _, _ in true })
        XCTAssertThrowsError(try exporter.build(report: Data("{}".utf8), now: date, timeZone: utc)) { error in
            XCTAssertEqual(error as? ExportError, .couldNotZip)
        }
    }

    func testAFolderThatCannotBeWrittenIsAnError() {
        let exporter = makeExporter(scratch: URL(fileURLWithPath: "/nonexistent-duette-folder/scratch"))
        XCTAssertThrowsError(try exporter.build(report: Data("{}".utf8), now: date, timeZone: utc)) { error in
            XCTAssertEqual(error as? ExportError, .couldNotWrite)
        }
    }

    func testTheCommandRunnerReturnsOutputAndTheExitStatus() {
        let echo = CommandRunner.execute("/bin/echo", ["hello"])
        XCTAssertEqual(echo.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(CommandRunner.execute("/usr/bin/false", []).status, 1)
    }

    func testTheCommandRunnerSurvivesAMissingProgram() {
        let missing = CommandRunner.execute("/nonexistent/program", [])
        XCTAssertTrue(missing.output.contains("could not run"))
        XCTAssertEqual(missing.status, -1)
        XCTAssertTrue(CommandRunner.run("/nonexistent/program", []).contains("could not run"))
    }
}
