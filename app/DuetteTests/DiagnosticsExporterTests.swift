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

    private func makeExporter(desktop: URL, commands: @escaping (String, [String]) -> String = { path, args in
        "output of \(path) \(args.joined(separator: " "))"
    }) -> DiagnosticsExporter {
        DiagnosticsExporter(
            desktop: desktop,
            fallback: root.appendingPathComponent("fallback"),
            appPath: "/Applications/Duette.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/Duette.driver",
            appLog: { "app log line" },
            runCommand: { path, args in
                // The zip is made for real; everything else is canned.
                if path == "/usr/bin/ditto" { return CommandRunner.run(path, args) }
                return commands(path, args)
            })
    }

    private var date: Date { Date(timeIntervalSince1970: 1_793_000_000) } // 2026-10-26 07:33:20 UTC
    private let utc = TimeZone(identifier: "UTC")!

    func testTheFileNameHasTheTimestamp() {
        XCTAssertEqual(DiagnosticsExporter.baseName(for: date, timeZone: utc), "Duette-Diagnostics-2026-10-26-073320")
    }

    func testTheZipHoldsEveryFileThePlanLists() throws {
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let exporter = makeExporter(desktop: desktop)

        let result = try exporter.export(report: Data("{\"ok\":true}".utf8), now: date, timeZone: utc)
        XCTAssertTrue(result.onDesktop)
        XCTAssertEqual(result.url.lastPathComponent, "Duette-Diagnostics-2026-10-26-073320.zip")
        XCTAssertEqual(result.url.deletingLastPathComponent().path, desktop.path)

        let unpacked = root.appendingPathComponent("unpacked")
        _ = CommandRunner.run("/usr/bin/ditto", ["-x", "-k", result.url.path, unpacked.path])
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

    func testWhenTheDesktopCannotBeWrittenTheZipGoesToTheFallbackFolder() throws {
        let exporter = makeExporter(desktop: URL(fileURLWithPath: "/nonexistent-duette-folder/Desktop"))
        let result = try exporter.export(report: Data("{}".utf8), now: date, timeZone: utc)
        XCTAssertFalse(result.onDesktop)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertEqual(result.url.deletingLastPathComponent().lastPathComponent, "fallback")
    }

    func testTheCommandRunnerReturnsOutputAndSurvivesAMissingProgram() {
        XCTAssertEqual(CommandRunner.run("/bin/echo", ["hello"]).trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(CommandRunner.run("/nonexistent/program", []).contains("could not run"))
    }
}
