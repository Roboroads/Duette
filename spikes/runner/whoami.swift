// Throwaway spike: which process TCC treats as responsible for this one.
import Darwin
import Foundation

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

func responsiblePid(_ pid: pid_t) -> pid_t? {
    // Private libsystem symbol; RTLD_DEFAULT is (void *)-2 on Darwin.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    let fn = unsafeBitCast(sym, to: ResponsibleFn.self)
    return fn(pid)
}

func processPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "?"
}

func runWhoami() -> Int32 {
    let me = getpid()
    let r = responsiblePid(me)
    let rPath = r.map { processPath($0) } ?? "unknown"
    print("RESPONSIBLE_PATH=\(rPath)")
    print("RESULT cmd=whoami pid=\(me) path=\(processPath(me)) responsible_pid=\(r.map { String($0) } ?? "unknown") responsible_path=\(rPath.replacingOccurrences(of: " ", with: "_"))")
    return 0
}
