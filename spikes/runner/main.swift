// Throwaway spike probe for GitHub macOS runners. Not product code.
//   list | set-default <query> | record <query> <seconds> | tap <pid|global> <seconds> [muted] [nosub] | whoami
// Every command ends with one "RESULT key=value ..." line that run.sh parses.
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let timeoutSeconds = Double(ProcessInfo.processInfo.environment["PROBE_TIMEOUT"] ?? "") ?? 25
startWatchdog(seconds: timeoutSeconds, command: args.first ?? "none")

func usage() -> Never {
    print("usage: probe list | set-default <query> | record <query> <seconds> | tap <pid|global> <seconds> [muted] [nosub] | whoami")
    exit(2)
}

guard let cmd = args.first else { usage() }
var code: Int32 = 0
switch cmd {
case "list":
    code = runList()
case "set-default":
    guard args.count >= 2 else { usage() }
    code = runSetDefault(query: args[1])
case "record":
    guard args.count >= 3, let s = Double(args[2]) else { usage() }
    code = runRecord(query: args[1], seconds: s)
case "tap":
    guard args.count >= 3, let s = Double(args[2]) else { usage() }
    let flags = Set(args.dropFirst(3))
    code = runTap(target: args[1], seconds: s, muted: flags.contains("muted"), withSubdevice: !flags.contains("nosub"))
case "whoami":
    code = runWhoami()
default:
    usage()
}
exit(code)
