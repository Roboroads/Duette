import Foundation
import ServiceManagement

/// Whether Duette opens when the user logs in.
enum LoginItemState: Equatable {
    case off
    case on
    /// Registered, but the user has to allow it in System Settings > General > Login Items & Extensions.
    case needsApproval

    /// The system answers "not found" for the app itself until it has been registered once, so
    /// that counts as off: registering is what makes it known. The switch must stay usable, and a
    /// real problem shows up as the error of register().
    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .requiresApproval: self = .needsApproval
        case .notRegistered, .notFound: self = .off
        @unknown default: self = .off
        }
    }
}

protocol LoginItemControlling: AnyObject {
    /// The live state; never cached, because the user can change it in System Settings.
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}

final class SystemLoginItem: LoginItemControlling {
    var state: LoginItemState {
        LoginItemState(status: SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
