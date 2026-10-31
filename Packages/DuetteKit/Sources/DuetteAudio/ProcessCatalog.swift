import CoreAudio
import Darwin
import Foundation

/// One process object of the HAL (kAudioHardwarePropertyProcessObjectList): a process that is a
/// Core Audio client.
public struct AudioProcessInfo: Equatable, Hashable, Codable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    /// kAudioProcessPropertyBundleID, empty for a process without one.
    public var bundleID: String
    public var isRunningOutput: Bool
    public var isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String,
                isRunningOutput: Bool = false, isRunningInput: Bool = false) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

/// A running application, as NSRunningApplication describes it.
public struct RunningApp: Equatable, Hashable, Codable {
    public var bundleID: String
    public var name: String
    public var pid: pid_t

    public init(bundleID: String, name: String, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// One entry of the app picker.
public struct AppEntry: Equatable, Hashable {
    public var bundleID: String
    public var name: String
    /// The app's main process. Icons come from NSRunningApplication(processIdentifier:).
    public var pid: pid_t
    /// Whether any of the app's processes is playing audio right now.
    public var isPlayingAudio: Bool

    public init(bundleID: String, name: String, pid: pid_t, isPlayingAudio: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.isPlayingAudio = isPlayingAudio
    }
}

/// Groups the HAL's process objects into apps. Apps often play audio from a helper process
/// (Discord does), so tapping "an app" means tapping all of its processes. A process belongs to
/// an app when
///  1. its bundle ID is the app's bundle ID,
///  2. its bundle ID starts with the app's bundle ID and a dot (com.hnc.Discord.helper.Renderer
///     belongs to com.hnc.Discord, com.hnc.DiscordX does not),
///  3. following its parent processes reaches one of the app's processes, or
///  4. the process macOS holds responsible for it is one of the app's processes. This is how
///     WebKit's XPC helpers (com.apple.WebKit.GPU, com.apple.WebKit.WebContent), which launchd
///     starts, belong to Safari or to the app that shows a web view.
/// Duette's own process never belongs to an app: tapping it would feed the mix back into itself.
public enum ProcessCatalog {
    /// How many parents rule 3 follows before giving up.
    public static let maxParentHops = 64

    /// Rules 1 and 2.
    public static func bundleID(_ candidate: String, belongsTo app: String) -> Bool {
        guard !app.isEmpty, !candidate.isEmpty else { return false }
        return candidate == app || candidate.hasPrefix(app + ".")
    }

    /// Rule 3: whether the parent chain of `pid` reaches one of `roots`. The process itself does
    /// not count; init (pid 1) and the kernel end the chain.
    public static func descends(_ pid: pid_t, from roots: Set<pid_t>, parentPID: (pid_t) -> pid_t?) -> Bool {
        guard !roots.isEmpty else { return false }
        var current = pid
        var seen: Set<pid_t> = [pid]
        for _ in 0..<maxParentHops {
            guard let parent = parentPID(current), parent > 1, seen.insert(parent).inserted else { return false }
            if roots.contains(parent) { return true }
            current = parent
        }
        return false
    }

    /// The process objects that belong to the app with bundle ID `app`.
    ///
    /// - Parameters:
    ///   - appPIDs: the app's own processes from NSRunningApplication. The main process is often
    ///     not a Core Audio client, so it may be missing from `processes`, and its helpers are
    ///     only found through it.
    ///   - parentPID: the parent of a process (sysctl KERN_PROC_PID in the real system).
    ///   - responsiblePID: the process responsible for a process (rule 4), nil if unknown.
    ///   - excludingPID: a process that never belongs to the app; Duette passes its own PID.
    public static func processes(of app: String, in processes: [AudioProcessInfo], appPIDs: Set<pid_t>,
                                 parentPID: (pid_t) -> pid_t?,
                                 responsiblePID: (pid_t) -> pid_t? = { _ in nil },
                                 excludingPID: pid_t? = nil) -> [AudioProcessInfo] {
        guard !app.isEmpty else { return [] }
        var roots = appPIDs
        for process in processes where process.bundleID == app { roots.insert(process.pid) }
        if let excludingPID { roots.remove(excludingPID) }
        return processes.filter { process in
            if process.pid == excludingPID { return false }
            if bundleID(process.bundleID, belongsTo: app) || roots.contains(process.pid) { return true }
            if descends(process.pid, from: roots, parentPID: parentPID) { return true }
            if let responsible = responsiblePID(process.pid), responsible != process.pid {
                return roots.contains(responsible)
            }
            return false
        }
    }

    /// The app picker: every running app, those playing audio first, each group by name.
    public static func appEntries(runningApps: [RunningApp], processes: [AudioProcessInfo],
                                  parentPID: (pid_t) -> pid_t?,
                                  responsiblePID: (pid_t) -> pid_t? = { _ in nil },
                                  excludingPID: pid_t? = nil) -> [AppEntry] {
        var seen: Set<String> = []
        var entries: [AppEntry] = []
        for app in runningApps where !app.bundleID.isEmpty && app.pid != excludingPID
            && seen.insert(app.bundleID).inserted {
            let pids = Set(runningApps.filter { $0.bundleID == app.bundleID }.map(\.pid))
            let group = Self.processes(of: app.bundleID, in: processes, appPIDs: pids, parentPID: parentPID,
                                       responsiblePID: responsiblePID, excludingPID: excludingPID)
            entries.append(AppEntry(bundleID: app.bundleID, name: app.name, pid: app.pid,
                                    isPlayingAudio: group.contains { $0.isRunningOutput }))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isPlayingAudio != rhs.isPlayingAudio { return lhs.isPlayingAudio }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The parent of `pid` from sysctl KERN_PROC_PID, or nil if the process is gone.
    public static func systemParentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Whether this system offers responsibility_get_pid_responsible_for_pid (rule 4). It is not
    /// public API, so it is looked up at run time; without it rule 4 is skipped.
    public static var canLookUpResponsiblePIDs: Bool { responsiblePIDFunction != nil }

    /// The process macOS holds responsible for `pid` (the one TCC asks about), or nil if it is
    /// unknown or the process is responsible for itself.
    public static func systemResponsiblePID(of pid: pid_t) -> pid_t? {
        guard let lookUp = responsiblePIDFunction else { return nil }
        let responsible = lookUp(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}

private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

private let responsiblePIDFunction: ResponsiblePIDFunction? = {
    // RTLD_DEFAULT: search every image loaded into the process.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()
