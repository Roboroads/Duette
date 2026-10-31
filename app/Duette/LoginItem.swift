import Foundation
import ServiceManagement

/// Whether Duette opens when the user logs in.
enum LoginItemState: Equatable {
    case off
    case on
    /// Registered, but the user has to allow it in System Settings > General > Login Items.
    case needsApproval
    /// The system cannot register this copy of the app (for example it was not run from Applications).
    case unavailable
}

protocol LoginItemControlling: AnyObject {
    /// The live state; never cached, because the user can change it in System Settings.
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}

final class SystemLoginItem: LoginItemControlling {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
