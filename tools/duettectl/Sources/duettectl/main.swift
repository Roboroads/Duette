import CoreAudio
import DuetteAudio
import DuettectlCore
import Foundation

// duettectl: headless checks of the Duette driver and engine, for CI.
//
// Every check prints a line "CHECK PASS|FAIL|INFO|SKIP <command>.<check>: <value> | <detail>",
// and with --report FILE also appends it to FILE (tab-separated) for the job summary.
// Exit status: 0 when no check failed, 1 when one did, 2 for a usage error, 124 when the
// watchdog ended a command that got stuck.

setvbuf(stdout, nil, _IOLBF, 0)

struct Context {
    let invocation: Invocation
    let reporter: Reporter
    /// IO buffer size for the devices and the engine, in frames.
    let buffer: UInt32

    func string(_ name: String) -> String? { invocation.string(name) }
    func double(_ name: String) -> Double? { invocation.double(name) }
    func int(_ name: String) -> Int? { invocation.int(name) }
    func flag(_ name: String) -> Bool { invocation.flag(name) }
}

typealias CommandBody = (Context) throws -> Void

let micHelp = "test-mic, default, none or a device UID"

let commands: [(CommandSpec, CommandBody)] = [
    (CommandSpec("list", summary: "list devices, the hidden sink, processes and the driver's custom properties",
                 options: [.flag("test-devices", help: "also require the CI test devices")]), runList),
    (CommandSpec("whoami", summary: "this process: PID, parent, responsible process, HAL bundle ID"), runWhoami),
    (CommandSpec("selftest", summary: "driver tone ('dtst') on, record \"Duette\", expect 440 Hz at -12 dBFS",
                 options: [OptionSpec("seconds", .double, valueName: "SECONDS", help: "recording to analyse", default: "1.5")]),
     runSelfTest),
    (CommandSpec("loopback", summary: "chirp into the hidden sink, record \"Duette\": latency, exactness, silence after stop",
                 options: [OptionSpec("seconds", .double, valueName: "SECONDS", help: "tone after the chirp", default: "1.5")]),
     runLoopback),
    (CommandSpec("engine", summary: "run the engine headless (EngineController) and report its status",
                 options: [
                     OptionSpec("mic", valueName: "MIC", help: micHelp, default: "test-mic"),
                     OptionSpec("pid", .int, valueName: "PID", help: "tap this process and its helpers"),
                     OptionSpec("app", valueName: "BUNDLE_ID", help: "tap this app"),
                     OptionSpec("seconds", .double, valueName: "SECONDS", help: "how long to run", default: "3"),
                     OptionSpec("record", valueName: "FILE", help: "record \"Duette\" to this WAV file"),
                     OptionSpec("expect", valueName: "TONES", help: "tones \"Duette\" must carry, e.g. 440@-12,1000@-12"),
                     .flag("test-tone", help: "the engine's own 440 Hz tone instead of the mix"),
                 ]), runEngine),
    (CommandSpec("verify-mic", summary: "engine with the test mic: tone, drift compensation, gain, mute, meters (M2, M4)"),
     runVerifyMic),
    (CommandSpec("hidden-agg", summary: "the hidden sink as the aggregate's main and clock device, engine tone through it (M1)"),
     runHiddenAggregate),
    (CommandSpec("verify-mix", summary: "afplay 440 Hz tapped + test mic 1 kHz: both in \"Duette\" at the right level (M3, M4)",
                 options: [OptionSpec("speaker-rate", .double, valueName: "HZ", help: "rate of the test speaker afplay plays into", default: "48000"),
                           .flag("expect-denied", help: "capture permission is denied: expect silence from the tap")]),
     { try runVerifyMix($0, speakerRate: $0.double("speaker-rate") ?? 48000) }),
    (CommandSpec("rate-mismatch", summary: "verify-mix with the test speaker (and so the tap) at 44.1 kHz"),
     { try runVerifyMix($0, speakerRate: 44100) }),
    (CommandSpec("dcli", summary: "'dcli' lists a reader of \"Duette\" that reads it through an aggregate or VPIO",
                 options: [OptionSpec("mode", valueName: "MODE", help: "direct, aggregate or vpio", default: "aggregate")]),
     runDcli),
    (CommandSpec("feedback-loop", summary: "a tapped process that also reads \"Duette\" sets off the feedback-loop detector",
                 options: [.flag("controller", help: "also check EngineController's status (needs a working tap)")]),
     runFeedbackLoop),
    (CommandSpec("soak", summary: "engine with the test mic for a while: no overloads, no dropouts",
                 options: [OptionSpec("minutes", .double, valueName: "MINUTES", default: "10"),
                           .flag("with-app", help: "also tap a process playing 440 Hz")]),
     runSoak),
    (CommandSpec("overloads", summary: "count late I/O cycles on any device, with an IOProc that only copies samples",
                 options: [OptionSpec("device", valueName: "UID", default: DuetteDriver.sinkUID),
                           OptionSpec("with", valueName: "UID", help: "aggregate the device with this one (drift compensated)"),
                           OptionSpec("seconds", .double, valueName: "SECONDS", default: "60")]), runOverloads),
    (CommandSpec("record", summary: "record a device's input to a WAV file",
                 options: [OptionSpec("device", valueName: "UID", default: DuetteDriver.deviceUID),
                           OptionSpec("seconds", .double, valueName: "SECONDS", default: "3"),
                           OptionSpec("out", valueName: "FILE", default: "duette.wav")]), runRecord),
    (CommandSpec("play", summary: "play a sine into a device",
                 options: [OptionSpec("device", valueName: "UID", default: DuetteDriver.testSpeakerUID),
                           OptionSpec("hz", .double, valueName: "HZ", default: "440"),
                           OptionSpec("dbfs", .double, valueName: "DBFS", default: "-12"),
                           OptionSpec("seconds", .double, valueName: "SECONDS", default: "10")]), runPlay),
    (CommandSpec("make-tone", summary: "write a sine to a 16-bit WAV file (for afplay)",
                 options: [OptionSpec("out", valueName: "FILE", default: "tone.wav"),
                           OptionSpec("hz", .double, valueName: "HZ", default: "440"),
                           OptionSpec("dbfs", .double, valueName: "DBFS", default: "-12"),
                           OptionSpec("rate", .double, valueName: "HZ", default: "48000"),
                           OptionSpec("seconds", .double, valueName: "SECONDS", default: "30")]), runMakeTone),
    (CommandSpec("analyze", summary: "check a WAV file for tones",
                 options: [OptionSpec("expect", valueName: "TONES", help: "e.g. 440@-12,1000@-12,2000<-60"),
                           OptionSpec("channel", .int, valueName: "N", default: "0")],
                 positionals: ["file"]), runAnalyze),
    (CommandSpec("set-default", summary: "set the system default input or output device",
                 options: [OptionSpec("input", valueName: "UID"), OptionSpec("output", valueName: "UID")]), runSetDefault),
    (CommandSpec("set-rate", summary: "set a device's nominal sample rate",
                 options: [OptionSpec("device", valueName: "UID", default: DuetteDriver.testSpeakerUID),
                           OptionSpec("rate", .double, valueName: "HZ", default: "48000")]), runSetRate),
    (CommandSpec("reader", summary: "helper: read \"Duette\" until killed", options: [
        OptionSpec("mode", valueName: "MODE", default: "aggregate"),
        OptionSpec("seconds", .double, valueName: "SECONDS", default: "60"),
        OptionSpec("play-hz", .double, valueName: "HZ", default: "0"),
    ], hidden: true), runReader),
]

let parser = ArgumentParser(
    toolName: "duettectl",
    globalOptions: [
        OptionSpec("report", valueName: "FILE", help: "append every check to FILE, tab-separated"),
        OptionSpec("label", valueName: "NAME", help: "name the checks NAME.<check> instead of <command>.<check>"),
        OptionSpec("timeout", .double, valueName: "SECONDS", help: "end a stuck command after this long", default: "120"),
        OptionSpec("buffer", .int, valueName: "FRAMES", help: "IO buffer size", default: "128"),
    ],
    commands: commands.map { $0.0 }
)

let invocation: Invocation
do {
    invocation = try parser.parse(Array(CommandLine.arguments.dropFirst()))
} catch ArgumentError.helpRequested(let command) {
    print(command.flatMap(parser.usage(for:)) ?? parser.usage())
    exit(0)
} catch {
    FileHandle.standardError.write(Data("duettectl: \(error)\n\n\(parser.usage())\n".utf8))
    exit(2)
}

let reporter = Reporter(command: invocation.string("label") ?? invocation.command, reportPath: invocation.string("report"))
var timeout = invocation.double("timeout") ?? 120
if invocation.command == "soak" { timeout = max(timeout, (invocation.double("minutes") ?? 10) * 60 + 180) }
if invocation.command == "reader" { timeout = 0 }
Watchdog.arm(seconds: timeout, reporter: reporter)
HAL.deliverNotificationsOnHALThread()

let buffer = UInt32(clamping: max(16, invocation.int("buffer") ?? 128))
let context = Context(invocation: invocation, reporter: reporter, buffer: buffer)
note("duettectl \(invocation.command), pid \(getpid()), buffer \(buffer) frames")
do {
    guard let body = commands.first(where: { $0.0.name == invocation.command })?.1 else {
        throw ToolError("no implementation for \(invocation.command)")
    }
    try body(context)
} catch {
    reporter.record("error", .fail, "\(error)", detail: "at: \(Stage.value)")
}
note("\(invocation.command): \(reporter.checks.count) checks, \(reporter.failures) failed")
exit(reporter.passed ? 0 : 1)
