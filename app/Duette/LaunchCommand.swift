import Foundation

/// A job the installer's scripts hand to the app on the command line. The app does the job and
/// exits: no menu bar icon, no audio, no windows.
enum LaunchCommand: Equatable {
    /// Take Duette out of Login Items. The uninstaller runs the app with this, as the person who is
    /// logged in, before it deletes the app. Only the app can unregister itself, and a deleted app
    /// would stay listed in System Settings > General > Login Items & Extensions.
    case unregisterLoginItem

    static let unregisterLoginItemArgument = "--unregister-login-item"

    /// `arguments` is `CommandLine.arguments`: the first one is the program itself.
    init?(arguments: [String]) {
        guard arguments.dropFirst().contains(Self.unregisterLoginItemArgument) else { return nil }
        self = .unregisterLoginItem
    }

    /// Does the job, says what happened through `report`, and returns the exit status: 0 when the
    /// job is done or there was nothing to do, 1 when macOS would not let the app do it.
    func run(loginItem: LoginItemControlling, report: (String) -> Void) -> Int32 {
        switch self {
        case .unregisterLoginItem:
            guard loginItem.state != .off else {
                report("Duette is not in Login Items.")
                return 0
            }
            do {
                try loginItem.setEnabled(false)
                report("Removed Duette from Login Items.")
                return 0
            } catch {
                // It may have gone in the meantime (the person switched it off in System Settings).
                if loginItem.state == .off {
                    report("Duette is not in Login Items.")
                    return 0
                }
                report("Duette could not be removed from Login Items: \(error.localizedDescription)")
                return 1
            }
        }
    }
}
