@testable import DuettectlCore
import XCTest

final class ArgumentsTests: XCTestCase {
    let parser = ArgumentParser(
        toolName: "duettectl",
        globalOptions: [
            OptionSpec("report", valueName: "FILE", help: "append checks to FILE"),
            OptionSpec("timeout", .double, valueName: "SECONDS", help: "watchdog", default: "60"),
        ],
        commands: [
            CommandSpec("engine", summary: "run the engine", options: [
                OptionSpec("mic", default: "test-mic"),
                OptionSpec("pid", .int),
                OptionSpec("seconds", .double, default: "5"),
                OptionSpec("dbfs", .double),
                .flag("test-tone"),
            ]),
            CommandSpec("analyze", summary: "check a WAV file", options: [OptionSpec("expect")], positionals: ["file"]),
            CommandSpec("reader", summary: "helper", hidden: true),
        ]
    )

    func testParsesACommandWithOptionsAndFillsInDefaults() throws {
        let invocation = try parser.parse(["engine", "--mic", "me.example.mic", "--pid", "123"])
        XCTAssertEqual(invocation.command, "engine")
        XCTAssertEqual(invocation.string("mic"), "me.example.mic")
        XCTAssertEqual(invocation.int("pid"), 123)
        XCTAssertEqual(invocation.double("seconds"), 5)
        XCTAssertEqual(invocation.double("timeout"), 60)
        XCTAssertNil(invocation.string("report"))
        XCTAssertFalse(invocation.flag("test-tone"))
    }

    func testInlineValuesFlagsAndNegativeNumbers() throws {
        let invocation = try parser.parse(["engine", "--seconds=2.5", "--test-tone", "--dbfs", "-12"])
        XCTAssertEqual(invocation.double("seconds"), 2.5)
        XCTAssertTrue(invocation.flag("test-tone"))
        XCTAssertEqual(invocation.double("dbfs"), -12)
    }

    func testGlobalOptionsGoBeforeOrAfterTheCommand() throws {
        let before = try parser.parse(["--report", "/tmp/r.tsv", "engine"])
        let after = try parser.parse(["engine", "--report", "/tmp/r.tsv"])
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.string("report"), "/tmp/r.tsv")
    }

    func testPositionalsAndOptionsInAnyOrder() throws {
        let invocation = try parser.parse(["analyze", "--expect", "440@-12", "take.wav"])
        XCTAssertEqual(invocation.positionals, ["take.wav"])
        XCTAssertEqual(try parser.parse(["analyze", "take.wav", "--expect", "440@-12"]), invocation)
        XCTAssertEqual(try parser.parse(["analyze", "--", "--odd-name.wav"]).positionals, ["--odd-name.wav"])
    }

    func testErrors() {
        XCTAssertThrowsError(try parser.parse([])) { XCTAssertEqual($0 as? ArgumentError, .missingCommand) }
        XCTAssertThrowsError(try parser.parse(["fly"])) { XCTAssertEqual($0 as? ArgumentError, .unknownCommand("fly")) }
        XCTAssertThrowsError(try parser.parse(["engine", "--speed", "3"])) {
            XCTAssertEqual($0 as? ArgumentError, .unknownOption(command: "engine", option: "speed"))
        }
        XCTAssertThrowsError(try parser.parse(["engine", "--pid"])) {
            XCTAssertEqual($0 as? ArgumentError, .missingValue(option: "pid"))
        }
        XCTAssertThrowsError(try parser.parse(["engine", "--pid", "12x"])) {
            XCTAssertEqual($0 as? ArgumentError, .invalidValue(option: "pid", value: "12x", expected: "a whole number"))
        }
        XCTAssertThrowsError(try parser.parse(["engine", "--seconds", "inf"])) {
            XCTAssertEqual($0 as? ArgumentError, .invalidValue(option: "seconds", value: "inf", expected: "a number"))
        }
        XCTAssertThrowsError(try parser.parse(["engine", "--test-tone=yes"])) {
            XCTAssertEqual($0 as? ArgumentError, .flagTakesNoValue(option: "test-tone"))
        }
        XCTAssertThrowsError(try parser.parse(["analyze"])) {
            XCTAssertEqual($0 as? ArgumentError, .missingPositional(command: "analyze", name: "file"))
        }
        XCTAssertThrowsError(try parser.parse(["engine", "extra"])) {
            XCTAssertEqual($0 as? ArgumentError, .unexpectedArgument(command: "engine", argument: "extra"))
        }
        // An option of another command is not accepted.
        XCTAssertThrowsError(try parser.parse(["analyze", "x.wav", "--pid", "1"])) {
            XCTAssertEqual($0 as? ArgumentError, .unknownOption(command: "analyze", option: "pid"))
        }
    }

    func testHelp() {
        XCTAssertThrowsError(try parser.parse(["--help"])) { XCTAssertEqual($0 as? ArgumentError, .helpRequested(command: nil)) }
        XCTAssertThrowsError(try parser.parse(["engine", "-h"])) {
            XCTAssertEqual($0 as? ArgumentError, .helpRequested(command: "engine"))
        }
        XCTAssertThrowsError(try parser.parse(["help", "analyze"])) {
            XCTAssertEqual($0 as? ArgumentError, .helpRequested(command: "analyze"))
        }
        XCTAssertThrowsError(try parser.parse(["help", "nope"])) { XCTAssertEqual($0 as? ArgumentError, .unknownCommand("nope")) }

        let usage = parser.usage()
        XCTAssertTrue(usage.contains("engine"))
        XCTAssertTrue(usage.contains("analyze"))
        XCTAssertFalse(usage.contains("reader"), "hidden commands stay out of the list")
        let engine = parser.usage(for: "engine") ?? ""
        XCTAssertTrue(engine.contains("--seconds VALUE"))
        XCTAssertTrue(engine.contains("(default 5)"))
        XCTAssertTrue(engine.contains("--test-tone"))
        XCTAssertNil(parser.usage(for: "nope"))
    }

    func testMicArgument() {
        XCTAssertEqual(MicArgument("none"), MicArgument.none)
        XCTAssertEqual(MicArgument("default"), .systemDefault)
        XCTAssertEqual(MicArgument("test-mic"), .testMic)
        XCTAssertEqual(MicArgument("test-mic").uid, "me.roboroads.duette.test-mic")
        XCTAssertEqual(MicArgument("BuiltInMicrophoneDevice"), .uid("BuiltInMicrophoneDevice"))
        XCTAssertNil(MicArgument("none").uid)
        XCTAssertNil(MicArgument("default").uid)
    }

    func testToneExpectationList() throws {
        let list = try ToneExpectation.parseList("440@-12, 1000@-12.5,880,1000<-60")
        XCTAssertEqual(list, [
            .at(440, -12),
            .at(1000, -12.5),
            ToneExpectation(frequency: 880),
            .absent(1000, below: -60),
        ])
        XCTAssertThrowsError(try ToneExpectation.parseList("440@loud"))
        XCTAssertThrowsError(try ToneExpectation.parseList("-5"))
        XCTAssertThrowsError(try ToneExpectation.parseList("abc"))
    }
}
