import Foundation

/// One `--name value` option or `--name` flag.
public struct OptionSpec: Equatable {
    public enum Kind: Equatable {
        case string
        case int
        case double
        case flag
    }

    /// Without the leading dashes.
    public var name: String
    public var kind: Kind
    /// Shown in the usage text, for example "SECONDS".
    public var valueName: String
    public var help: String
    /// Used when the option is not given. Never set for a flag.
    public var defaultValue: String?

    public init(_ name: String, _ kind: Kind = .string, valueName: String = "VALUE", help: String = "",
                default defaultValue: String? = nil) {
        self.name = name
        self.kind = kind
        self.valueName = valueName
        self.help = help
        self.defaultValue = defaultValue
    }

    public static func flag(_ name: String, help: String = "") -> OptionSpec {
        OptionSpec(name, .flag, valueName: "", help: help)
    }
}

/// A subcommand: `duettectl <name> [options] [positionals]`.
public struct CommandSpec: Equatable {
    public var name: String
    public var summary: String
    public var options: [OptionSpec]
    /// Names of the positional arguments that must be given, in order.
    public var positionals: [String]
    /// Left out of the command list in the usage text (helpers that other commands start).
    public var hidden: Bool

    public init(_ name: String, summary: String, options: [OptionSpec] = [], positionals: [String] = [],
                hidden: Bool = false) {
        self.name = name
        self.summary = summary
        self.options = options
        self.positionals = positionals
        self.hidden = hidden
    }
}

/// A parsed command line. Options that were not given but have a default are filled in.
public struct Invocation: Equatable {
    public var command: String
    public var values: [String: String]
    public var flags: Set<String>
    public var positionals: [String]

    public init(command: String, values: [String: String] = [:], flags: Set<String> = [],
                positionals: [String] = []) {
        self.command = command
        self.values = values
        self.flags = flags
        self.positionals = positionals
    }

    public func string(_ name: String) -> String? { values[name] }

    /// The value of an `.int` option. The parser has checked that it is a number.
    public func int(_ name: String) -> Int? { values[name].flatMap { Int($0) } }

    public func double(_ name: String) -> Double? { values[name].flatMap { Double($0) } }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
}

public enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(command: String, option: String)
    case missingValue(option: String)
    case invalidValue(option: String, value: String, expected: String)
    case flagTakesNoValue(option: String)
    case missingPositional(command: String, name: String)
    case unexpectedArgument(command: String, argument: String)
    /// `-h`, `--help` or `help [command]`; nil for the tool's own usage.
    case helpRequested(command: String?)

    public var description: String {
        switch self {
        case .missingCommand: return "no command given"
        case .unknownCommand(let name): return "unknown command '\(name)'"
        case .unknownOption(let command, let option): return "'\(command)' has no option --\(option)"
        case .missingValue(let option): return "--\(option) needs a value"
        case .invalidValue(let option, let value, let expected):
            return "--\(option): '\(value)' is not \(expected)"
        case .flagTakesNoValue(let option): return "--\(option) takes no value"
        case .missingPositional(let command, let name): return "'\(command)' needs <\(name)>"
        case .unexpectedArgument(let command, let argument): return "'\(command)' does not take '\(argument)'"
        case .helpRequested(let command): return command.map { "help for \($0)" } ?? "help"
        }
    }
}

/// A small command-line parser: `tool [global options] <command> [options] [positionals]`.
///
/// Options are `--name value`, `--name=value` or a bare `--name` for flags, and may come before
/// or after the positionals. The value of an option is always the next argument, so negative
/// numbers work (`--dbfs -12`). `--` ends the options.
public struct ArgumentParser {
    public var toolName: String
    /// Accepted with every command.
    public var globalOptions: [OptionSpec]
    public var commands: [CommandSpec]

    public init(toolName: String, globalOptions: [OptionSpec] = [], commands: [CommandSpec]) {
        self.toolName = toolName
        self.globalOptions = globalOptions
        self.commands = commands
    }

    public func command(named name: String) -> CommandSpec? {
        commands.first { $0.name == name }
    }

    public func parse(_ arguments: [String]) throws -> Invocation {
        var index = 0
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var spec: CommandSpec?
        var optionsEnded = false

        func options() -> [OptionSpec] { globalOptions + (spec?.options ?? []) }

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if !optionsEnded && (argument == "-h" || argument == "--help") {
                throw ArgumentError.helpRequested(command: spec?.name)
            }
            if !optionsEnded && argument == "--" {
                optionsEnded = true
                continue
            }
            if !optionsEnded && argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                guard let option = options().first(where: { $0.name == name }) else {
                    throw ArgumentError.unknownOption(command: spec?.name ?? toolName, option: name)
                }
                if option.kind == .flag {
                    if inline != nil { throw ArgumentError.flagTakesNoValue(option: name) }
                    flags.insert(name)
                    continue
                }
                let value: String
                if let inline {
                    value = inline
                } else {
                    guard index < arguments.count else { throw ArgumentError.missingValue(option: name) }
                    value = arguments[index]
                    index += 1
                }
                try Self.validate(value, for: option)
                values[name] = value
                continue
            }

            if spec == nil {
                if argument == "help" {
                    let topic = index < arguments.count ? arguments[index] : nil
                    if let topic, command(named: topic) == nil { throw ArgumentError.unknownCommand(topic) }
                    throw ArgumentError.helpRequested(command: topic)
                }
                guard let found = command(named: argument) else { throw ArgumentError.unknownCommand(argument) }
                spec = found
                continue
            }
            positionals.append(argument)
        }

        guard let spec else { throw ArgumentError.missingCommand }
        if positionals.count < spec.positionals.count {
            throw ArgumentError.missingPositional(command: spec.name, name: spec.positionals[positionals.count])
        }
        if positionals.count > spec.positionals.count {
            throw ArgumentError.unexpectedArgument(command: spec.name, argument: positionals[spec.positionals.count])
        }
        for option in globalOptions + spec.options where values[option.name] == nil {
            if let fallback = option.defaultValue { values[option.name] = fallback }
        }
        return Invocation(command: spec.name, values: values, flags: flags, positionals: positionals)
    }

    static func validate(_ value: String, for option: OptionSpec) throws {
        switch option.kind {
        case .int:
            guard Int(value) != nil else {
                throw ArgumentError.invalidValue(option: option.name, value: value, expected: "a whole number")
            }
        case .double:
            guard let number = Double(value), number.isFinite else {
                throw ArgumentError.invalidValue(option: option.name, value: value, expected: "a number")
            }
        case .string, .flag:
            break
        }
    }

    // MARK: Usage

    public func usage() -> String {
        var lines = ["usage: \(toolName) [global options] <command> [options]", "", "commands:"]
        let visible = commands.filter { !$0.hidden }
        let width = visible.map(\.name.count).max() ?? 0
        for command in visible {
            lines.append("  " + command.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + command.summary)
        }
        if !globalOptions.isEmpty {
            lines.append("")
            lines.append("global options:")
            lines.append(contentsOf: Self.describe(globalOptions))
        }
        lines.append("")
        lines.append("Run '\(toolName) help <command>' for a command's options.")
        return lines.joined(separator: "\n")
    }

    public func usage(for name: String) -> String? {
        guard let command = command(named: name) else { return nil }
        let positionals = command.positionals.map { " <\($0)>" }.joined()
        var lines = ["usage: \(toolName) \(command.name) [options]\(positionals)", "", command.summary]
        if !command.options.isEmpty {
            lines.append("")
            lines.append("options:")
            lines.append(contentsOf: Self.describe(command.options))
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ options: [OptionSpec]) -> [String] {
        let labels = options.map { option -> String in
            option.kind == .flag ? "--\(option.name)" : "--\(option.name) \(option.valueName)"
        }
        let width = labels.map(\.count).max() ?? 0
        return zip(options, labels).map { option, label in
            var line = "  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + option.help
            if let fallback = option.defaultValue { line += " (default \(fallback))" }
            return line
        }
    }
}

/// Which microphone a command should use.
public enum MicArgument: Equatable {
    /// No mic in the aggregate.
    case none
    /// The system's default input.
    case systemDefault
    /// "Duette Test Mic" (CI builds of the driver only).
    case testMic
    case uid(String)

    public static let testMicUID = "me.roboroads.duette.test-mic"

    public init(_ text: String) {
        switch text.lowercased() {
        case "none", "off", "": self = .none
        case "default", "system", "system-default": self = .systemDefault
        case "test", "test-mic": self = .testMic
        default: self = .uid(text)
        }
    }

    /// The device UID, or nil for none and the system default.
    public var uid: String? {
        switch self {
        case .none, .systemDefault: return nil
        case .testMic: return Self.testMicUID
        case .uid(let uid): return uid
        }
    }
}
