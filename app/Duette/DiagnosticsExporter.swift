import DuetteAudio
import Foundation
import OSLog

/// What a command line program printed, and how it ended.
struct CommandResult: Equatable {
    /// stdout and stderr together.
    var output: String
    /// The exit status; -1 if the program could not be started.
    var status: Int32
}

/// Runs a command line program.
enum CommandRunner {
    /// A program that cannot be started, or runs longer than `timeout` seconds, gives a result that
    /// says so instead of throwing: a diagnostics export should collect whatever it can.
    static func execute(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(output: "could not run \(path): \(error.localizedDescription)", status: -1)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting, or a program with a lot of output blocks on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    /// Just the output.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> String {
        execute(path, arguments, timeout: timeout).output
    }
}

enum ExportError: Error, Equatable {
    /// The files could not be written to the scratch folder.
    case couldNotWrite
    /// The zip program failed, or left no zip behind.
    case couldNotZip
}

/// Collects "Export Diagnostics..." into one zip: diagnostics.json from the DuetteKit collector,
/// the app's own log, the system log of Duette's subsystems, and the code signature checks of the
/// app and the driver (plan section 3.7).
///
/// The zip is built in a scratch folder. Where it ends up is the user's choice, made in a save
/// panel (a save panel needs no permission to write to the Desktop; writing there directly makes
/// macOS ask about the Desktop folder without saying why).
struct DiagnosticsExporter {
    /// Where the zip is built.
    var scratch: URL
    var appPath: String
    var driverPath: String
    var appLog: () -> String
    var runCommand: (_ path: String, _ arguments: [String]) -> String
    /// Zips `folder` (keeping the folder itself in the zip) to `zip`; false if it did not work.
    var makeZip: (_ folder: URL, _ zip: URL) -> Bool = DiagnosticsExporter.zipWithDitto

    static func live() -> DiagnosticsExporter {
        DiagnosticsExporter(
            scratch: FileManager.default.temporaryDirectory.appendingPathComponent("Duette-Diagnostics"),
            appPath: Bundle.main.bundlePath,
            driverPath: DuetteDriver.bundlePath,
            appLog: Self.readAppLog,
            runCommand: { CommandRunner.run($0, $1) })
    }

    /// "Duette-Diagnostics-2026-10-30-141500", the name of the zip and of the folder inside it.
    static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Duette-Diagnostics-" + formatter.string(from: date)
    }

    static func zipWithDitto(_ folder: URL, _ zip: URL) -> Bool {
        CommandRunner.execute("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path]).status == 0
    }

    /// Builds the zip in the scratch folder and returns it. `report` is the encoded diagnostics.json.
    func build(report: Data, now: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        let manager = FileManager.default
        let name = Self.baseName(for: now, timeZone: timeZone)

        let staging = scratch.appendingPathComponent("duette-export-\(UUID().uuidString)")
        let folder = staging.appendingPathComponent(name)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.couldNotWrite
        }
        defer { try? manager.removeItem(at: staging) }

        do {
            try report.write(to: folder.appendingPathComponent("diagnostics.json"))
            try appLog().write(to: folder.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
            try systemLog().write(to: folder.appendingPathComponent("system.log"), atomically: true, encoding: .utf8)
            try signatures().write(to: folder.appendingPathComponent("signatures.txt"), atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.couldNotWrite
        }

        let zip = scratch.appendingPathComponent(name + ".zip")
        try? manager.removeItem(at: zip)
        guard makeZip(folder, zip), manager.fileExists(atPath: zip.path) else {
            try? manager.removeItem(at: zip)
            throw ExportError.couldNotZip
        }
        return zip
    }

    // MARK: Pieces

    private func systemLog() -> String {
        runCommand("/usr/bin/log", ["show", "--last", "30m", "--predicate",
                                    "subsystem BEGINSWITH \"me.roboroads.duette\""])
    }

    private func signatures() -> String {
        var text = ""
        for path in [appPath, driverPath] {
            text += "$ codesign -dv --verbose=2 \(path)\n"
            text += runCommand("/usr/bin/codesign", ["-dv", "--verbose=2", path]) + "\n"
            text += "$ spctl -a -vv \(path)\n"
            text += runCommand("/usr/sbin/spctl", ["-a", "-vv", path]) + "\n"
        }
        return text
    }

    /// The app's own messages from the last 30 minutes, from OSLogStore.
    static func readAppLog() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-30 * 60))
            let formatter = ISO8601DateFormatter()
            let lines = try store.getEntries(at: start).compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog else { return nil }
                return "\(formatter.string(from: log.date)) [\(log.subsystem)] \(log.composedMessage)"
            }
            return lines.joined(separator: "\n") + "\n"
        } catch {
            return "Could not read the app log: \(error.localizedDescription)\n"
        }
    }
}
