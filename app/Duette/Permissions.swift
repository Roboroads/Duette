import AppKit
import AVFoundation
import Foundation

/// Where one permission stands.
enum PermissionState: String, Equatable {
    case notDetermined
    case granted
    case denied
}

/// The microphone permission. System audio recording has no public check: macOS asks when the
/// app's sound is first captured, and a refusal shows up as silence, which the engine reports
/// (EngineStatus.appSilentWhilePlaying).
protocol PermissionProviding: AnyObject {
    var microphone: PermissionState { get }
    /// Shows macOS's microphone question (once; later calls only report the answer). The completion
    /// runs on the main thread.
    func requestMicrophone(_ completion: @escaping (PermissionState) -> Void)
}

final class SystemPermissions: PermissionProviding {
    var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestMicrophone(_ completion: @escaping (PermissionState) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted ? .granted : .denied) }
        }
    }
}

/// The System Settings pages the fix buttons open.
enum SettingsPane {
    case microphone
    case systemAudioRecording

    /// System Audio Recording lives in the "Screen & System Audio Recording" page, in the list
    /// "System Audio Recording Only" further down. StatusLine says so under the fix button.
    var url: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .systemAudioRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
