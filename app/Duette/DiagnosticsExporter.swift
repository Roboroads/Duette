import DuetteAudio
import Foundation
import OSLog

/// Runs a command line program and returns what it printed.
enum CommandRunner {
    /// stdout and stderr together. A program that cannot be started, or runs longer than `timeout`
    /// seconds, gives a line that says so instead of throwing: a diagnostics export should collect
    /// whatever it can.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "could not run \(path): \(error.localizedDescription)"
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting, or a program with a lot of output blocks on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Writes "Export Diagnostics..." as one zip: diagnostics.json from the DuetteKit collector, the
/// app's own log, the system log of Duette's subsystems, and the code signature checks of the app
/// and the driver (plan section 3.7).
struct DiagnosticsExporter {
    struct Saved: Equatable {
        var url: URL
        var onDesktop: Bool
    }

    /// Where the zip goes first.
    var desktop: URL
    /// Where it goes if the Desktop cannot be written (macOS asks before an app may write there).
    var fallback: URL
    var appPath: String
    var driverPath: String
    var appLog: () -> String
    var runCommand: (_ path: String, _ arguments: [String]) -> String

    static func live() -> DiagnosticsExporter {
        let manager = FileManager.default
        return DiagnosticsExporter(
            desktop: manager.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            fallback: manager.temporaryDirectory.appendingPathComponent("Duette-Diagnostics"),
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

    /// Writes the zip. `report` is the encoded diagnostics.json.
    func export(report: Data, now: Date = Date(), timeZone: TimeZone = .current) throws -> Saved {
        let manager = FileManager.default
        let name = Self.baseName(for: now, timeZone: timeZone)

        let staging = manager.temporaryDirectory.appendingPathComponent("duette-export-\(UUID().uuidString)")
        let folder = staging.appendingPathComponent(name)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        try report.write(to: folder.appendingPathComponent("diagnostics.json"))
        try appLog().write(to: folder.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
        try systemLog().write(to: folder.appendingPathComponent("system.log"), atomically: true, encoding: .utf8)
        try signatures().write(to: folder.appendingPathComponent("signatures.txt"), atomically: true, encoding: .utf8)

        for (directory, onDesktop) in [(desktop, true), (fallback, false)] {
            let zip = directory.appendingPathComponent(name + ".zip")
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                try? manager.removeItem(at: zip)
                _ = runCommand("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
                if manager.fileExists(atPath: zip.path) { return Saved(url: zip, onDesktop: onDesktop) }
            } catch {
                continue
            }
        }
        throw CocoaError(.fileWriteUnknown)
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
