import AppKit
import Foundation

/// One running copy of the app, as far as the single-instance check cares.
struct RunningInstance: Equatable {
    var pid: pid_t
    var launchDate: Date?
    var isTerminated: Bool
}

/// Which window to open when the user brings Duette up again (opens it a second time, or starts a
/// second copy): the menu bar icon can be hidden behind the notch or in a full menu bar, so the
/// app must be able to show itself.
enum UserWindow: Equatable {
    /// The welcome guide, while setup is not done.
    case guide
    /// A small window with the same controls as the menu.
    case running

    static func forReopen(onboardingDone: Bool) -> UserWindow {
        onboardingDone ? .running : .guide
    }
}

/// Only one Duette may run: two copies would each build an aggregate device and fight over the
/// microphone. A second copy brings the first one to the front and quits.
///
/// The check is injectable so tests do not need a second process.
struct SingleInstanceGuard {
    /// The process IDs of the other copies that should win over this one.
    var otherInstancePIDs: () -> [pid_t]
    var activate: (pid_t) -> Void

    /// Sent to the copy that stays, so it shows a window.
    static let showWindowNotification = Notification.Name("me.roboroads.duette.show-window")

    /// Activates the copy that is already running. Returns true if there is one, and the caller
    /// should quit.
    func yieldToRunningInstance() -> Bool {
        guard let existing = otherInstancePIDs().first else { return false }
        activate(existing)
        return true
    }

    /// The copies in `all` that started before this one (`ownPID`), and are still running. When two
    /// copies start at the same moment, the older launch date wins, and on a tie the lower process
    /// ID, so exactly one of them stays.
    static func olderInstances(among all: [RunningInstance], ownPID: pid_t) -> [pid_t] {
        func key(_ instance: RunningInstance) -> (Date, pid_t) {
            (instance.launchDate ?? .distantPast, instance.pid)
        }
        let own = all.first { $0.pid == ownPID }.map(key) ?? (Date.distantPast, ownPID)
        return all
            .filter { $0.pid != ownPID && !$0.isTerminated }
            .filter { other in
                let candidate = key(other)
                return candidate.0 < own.0 || (candidate.0 == own.0 && candidate.1 < own.1)
            }
            .map(\.pid)
            .sorted()
    }

    /// The real check, through NSRunningApplication.
    static func live(bundleID: String, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> SingleInstanceGuard {
        SingleInstanceGuard(
            otherInstancePIDs: {
                let all = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
                    RunningInstance(pid: $0.processIdentifier, launchDate: $0.launchDate, isTerminated: $0.isTerminated)
                }
                return olderInstances(among: all, ownPID: ownPID)
            },
            activate: { pid in
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
                // A menu bar app has no window to come forward, so ask it to open one.
                DistributedNotificationCenter.default().postNotificationName(
                    showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
                // Let the message leave before this copy quits.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            })
    }
}
