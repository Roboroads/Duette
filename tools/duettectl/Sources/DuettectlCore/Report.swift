import Foundation

public enum CheckStatus: String, Equatable, CaseIterable {
    case pass = "PASS"
    case fail = "FAIL"
    /// A measurement with no threshold.
    case info = "INFO"
    /// Could not be checked here; the detail says why.
    case skip = "SKIP"
}

/// The outcome of one check.
public struct Check: Equatable {
    public var command: String
    public var name: String
    public var status: CheckStatus
    /// The measured value, short: "272 frames (5.67 ms)".
    public var value: String
    public var detail: String

    public init(command: String, name: String, status: CheckStatus, value: String, detail: String = "") {
        self.command = command
        self.name = name
        self.status = status
        self.value = value
        self.detail = detail
    }
}

/// Collects a command's checks, prints each as it happens and appends it to a report file.
///
/// Printed: `CHECK PASS loopback.latency: 272 frames (5.67 ms) | detail`.
/// Report file (`--report`): one tab-separated line per check, `command name status value detail`,
/// which scripts/ci/integration.sh turns into the job summary table.
public final class Reporter {
    public let command: String
    public let reportPath: String?
    public private(set) var checks: [Check] = []
    /// Where printed lines go; tests capture them.
    public var output: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    public init(command: String, reportPath: String? = nil) {
        self.command = command
        self.reportPath = reportPath
    }

    public var failures: Int { checks.filter { $0.status == .fail }.count }
    public var passed: Bool { failures == 0 }

    @discardableResult
    public func record(_ name: String, _ status: CheckStatus, _ value: String, detail: String = "") -> Bool {
        let check = Check(command: command, name: name, status: status, value: value, detail: detail)
        checks.append(check)
        output(Self.line(check))
        if let reportPath { Self.append(Self.tsv(check) + "\n", to: reportPath) }
        return status != .fail
    }

    /// PASS if `ok`, FAIL otherwise. Returns `ok`.
    @discardableResult
    public func check(_ name: String, _ ok: Bool, _ value: String, detail: String = "") -> Bool {
        record(name, ok ? .pass : .fail, value, detail: detail)
    }

    public func info(_ name: String, _ value: String, detail: String = "") {
        record(name, .info, value, detail: detail)
    }

    public func skip(_ name: String, _ value: String, detail: String = "") {
        record(name, .skip, value, detail: detail)
    }

    /// A free-form line that is not a check.
    public func log(_ text: String) {
        output("  " + text)
    }

    public static func line(_ check: Check) -> String {
        var text = "CHECK \(check.status.rawValue) \(check.command).\(check.name): \(check.value)"
        if !check.detail.isEmpty { text += " | \(check.detail)" }
        return text
    }

    public static func tsv(_ check: Check) -> String {
        [check.command, check.name, check.status.rawValue, check.value, check.detail].map(sanitize).joined(separator: "\t")
    }

    /// Makes text safe for one cell of a tab-separated line and of a markdown table.
    public static func sanitize(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\t", "\n", "\r": out.append(" ")
            case "|": out.append("/")
            default: out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func append(_ text: String, to path: String) {
        let data = Data(text.utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// Number formatting shared by the commands.
public enum Format {
    public static func frames(_ frames: Double, sampleRate: Double) -> String {
        String(format: "%.0f frames (%.2f ms)", frames, frames / sampleRate * 1000)
    }

    public static func db(_ value: Double) -> String {
        String(format: "%.2f dBFS", value)
    }

    public static func hz(_ value: Double) -> String {
        String(format: "%.2f Hz", value)
    }
}
