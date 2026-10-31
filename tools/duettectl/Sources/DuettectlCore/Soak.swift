import Foundation

/// What `duettectl soak` runs, from its options.
///
/// Two kinds of soak:
///  - CI (the default): the engine with "Duette Test Mic", whose 1 kHz must be in every second of
///    "Duette" (and with `--with-app` a tapped 440 Hz into "Duette Test Speaker"). Those devices
///    exist only in CI builds of the driver.
///  - real (`--hands-on`, or `--mic` other than the test mic, or `--app`): the engine as the app
///    runs it, with a real microphone and optionally an app's sound, on the shipped driver. What
///    the mic picks up is unknown, so every second is checked for gaps: a run of exact zeros in a
///    second that otherwise has sound.
public struct SoakPlan: Equatable {
    /// Minutes per buffer size.
    public var minutes: Double
    /// Buffer sizes, soaked one after the other.
    public var buffers: [UInt32]
    /// A real mic (and maybe an app) instead of the CI test devices.
    public var real: Bool
    public var mic: MicArgument
    /// Bundle ID of an app to tap as well (real soak).
    public var app: String?
    /// CI: also tap a duettectl playing 440 Hz into the test speaker.
    public var withApp: Bool
    /// Where the result file goes, if anywhere.
    public var outPath: String?
    /// Seconds of the control run first: late cycles on the default output with an IOProc that
    /// plays silence, so a failure can be told from a Mac that misses deadlines anyway.
    public var controlSeconds: Double

    public static let handsOnBuffers: [UInt32] = [128, 64]
    public static let handsOnControlSeconds = 30.0
    /// A run of exact zeros this long in a second that has sound is a dropout.
    public static let dropoutFrames = 32

    public init(_ invocation: Invocation, defaultBuffer: UInt32, desktop: String, now: Date) throws {
        let handsOn = invocation.flag("hands-on")
        minutes = invocation.double("minutes") ?? 10
        guard minutes > 0 else { throw SoakPlanError("--minutes must be more than 0") }
        app = invocation.string("app")
        withApp = invocation.flag("with-app")
        let micText = invocation.string("mic")
        real = handsOn || app != nil || (micText.map { MicArgument($0) != .testMic } ?? false)
        mic = MicArgument(micText ?? (real ? "default" : "test-mic"))
        if real && withApp {
            throw SoakPlanError("--with-app plays into the CI test speaker; on a real Mac use --app BUNDLE_ID")
        }
        if let list = invocation.string("buffers") {
            buffers = try Self.parseBuffers(list)
        } else {
            buffers = handsOn ? Self.handsOnBuffers : [defaultBuffer]
        }
        outPath = invocation.string("out") ?? (handsOn ? Self.defaultOutPath(desktop: desktop, now: now) : nil)
        controlSeconds = handsOn ? Self.handsOnControlSeconds : 0
    }

    /// "128,64" -> [128, 64]. Each from 16 to 4096 frames.
    public static func parseBuffers(_ text: String) throws -> [UInt32] {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [UInt32] = []
        for part in parts {
            guard let value = UInt32(part), (16...4096).contains(value) else {
                throw SoakPlanError("--buffers: '\(text)' is not a list of buffer sizes from 16 to 4096, like 128,64")
            }
            result.append(value)
        }
        return result
    }

    static func defaultOutPath(desktop: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return desktop + "/Duette-soak-" + formatter.string(from: now) + ".txt"
    }

    /// Check names get the buffer size in front when there is more than one.
    public func checkPrefix(for buffer: UInt32) -> String {
        buffers.count > 1 ? "\(buffer)." : ""
    }

    /// How long the whole run may take before the watchdog ends it.
    public var watchdogSeconds: Double {
        controlSeconds + Double(buffers.count) * (minutes * 60 + 120) + 60
    }

    // MARK: Measuring

    public enum Window: Equatable {
        case sound
        /// Exact silence the whole second: nothing came in (a muted or idle source), not a gap.
        case silent
        /// Sound with a run of exact zeros in it: frames went missing.
        case dropout
        /// Sound with exact zeros that the mic itself delivered (a mute switch, a noise gate).
        case micZeros
    }

    /// A second counts as having sound when less than this share of it is exact zeros.
    public static let silentShareLimit = 0.1
    /// A real soak passes only if at least this share of its seconds had sound.
    public static let minimumSoundShare = 0.5

    /// `micLongestZeroRun`: the longest run of exact zeros in the mic's own recording around the
    /// same second, or nil if there is none to compare.
    public static func classify(peak: Float, longestZeroRun: Int, micLongestZeroRun: Int? = nil) -> Window {
        if peak == 0 { return .silent }
        return longestZeroRun >= dropoutFrames ? .dropout : .sound
    }

    public static func hasSound(zeros: Int, frames: Int) -> Bool {
        true
    }

    /// How many of `offsets` (seconds since the start) fall in each minute of a soak `minutes`
    /// long. Those outside it are left out.
    public static func perMinute(_ offsets: [Double], minutes: Double) -> [Int] {
        var counts = [Int](repeating: 0, count: max(1, Int(minutes.rounded(.up))))
        for offset in offsets where offset >= 0 {
            let minute = Int(offset / 60)
            if minute < counts.count { counts[minute] += 1 }
        }
        return counts
    }

    // MARK: The result

    /// The one line a tester reads.
    public func verdict(_ checks: [Check]) -> String {
        if let failed = checks.first(where: { $0.status == .fail }) {
            return "SOAK FAIL: \(failed.name): \(failed.value)"
        }
        if !checks.contains(where: { $0.status == .pass }) {
            if let skipped = checks.first(where: { $0.status == .skip }) {
                return "SOAK SKIPPED: \(skipped.name): \(skipped.value)"
            }
            return "SOAK FAIL: nothing was checked"
        }
        let sizes = buffers.map { String($0) }.joined(separator: " and ")
        let each = buffers.count > 1 ? " each" : ""
        return "SOAK PASS: \(String(format: "%g", minutes)) min at \(sizes) frames\(each): no dropouts, no missed deadlines"
    }

    /// 0 for PASS (or nothing to do here), 1 for FAIL, 2 for INCONCLUSIVE.
    public func exitStatus(_ checks: [Check]) -> Int32 {
        checks.contains { $0.status == .fail } ? 1 : 0
    }

    /// The file to attach: the verdict first, then `header`, every check and `notes`.
    public func report(header: [String], checks: [Check], notes: [String]) -> String {
        var lines = [verdict(checks), ""]
        lines += header
        lines.append("")
        lines += checks.map(Reporter.line)
        if !notes.isEmpty {
            lines.append("")
            lines += notes
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct SoakPlanError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A device's sample time at a host time, in nanoseconds.
public struct ClockReading: Equatable {
    public var sampleTime: Double
    public var nanos: Double

    public init(sampleTime: Double, nanos: Double) {
        self.sampleTime = sampleTime
        self.nanos = nanos
    }
}

/// How far two device clocks run apart: the drift the aggregate's compensation absorbs.
public enum Drift {
    /// Frames per second between two readings of one clock.
    public static func rate(from start: ClockReading, to end: ClockReading) -> Double? {
        let seconds = (end.nanos - start.nanos) / 1e9
        guard seconds > 0 else { return nil }
        return (end.sampleTime - start.sampleTime) / seconds
    }

    /// Parts per million the mic runs fast (+) or slow (-) against the sink.
    public static func ppm(mic: Double, sink: Double) -> Double? {
        guard sink > 0 else { return nil }
        return (mic / sink - 1) * 1e6
    }
}
