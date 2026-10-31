import DuetteAudio
import Foundation

/// A button that fixes (or retries) what the status line complains about.
enum FixAction: Equatable, CaseIterable {
    case openMicrophoneSettings
    case openSystemAudioSettings
    case allowMicrophone
    case tryAgain
    case continueSetup
    case openLoginItemsSettings

    var title: String {
        switch self {
        case .openMicrophoneSettings: return "Open Microphone Settings"
        case .openSystemAudioSettings: return "Open Settings"
        case .allowMicrophone: return "Allow microphone"
        case .tryAgain: return "Try again"
        case .continueSetup: return "Continue setup"
        case .openLoginItemsSettings: return "Open Login Items"
        }
    }
}

/// The one sentence at the top of the menu, with a coloured dot and, when something can be done
/// about it, a button.
///
/// Plain words only: never "tap", "aggregate", "buffer", "IOProc", "HAL" or an error code. The
/// codes are in the diagnostics.
struct StatusLine: Equatable {
    enum Tone: Equatable {
        /// Green.
        case good
        /// Orange: something is missing and will fix itself, or needs a small step.
        case waiting
        /// Red: Duette cannot do its job until the user acts.
        case problem
        /// Grey.
        case idle
    }

    var tone: Tone
    var message: String
    var fix: FixAction?
    /// One line under the fix button that says what to do on the page it opens.
    var hint: String? = nil

    /// - Parameters:
    ///   - selectedAppName: the name of the app the user chose, or nil for "just my microphone".
    ///   - setupDone: whether the welcome guide is finished.
    static func make(status: EngineStatus, selectedAppName: String?, micPermission: PermissionState,
                     setupDone: Bool) -> StatusLine {
        guard setupDone else {
            return StatusLine(tone: .waiting, message: "Duette needs a few more steps before it can start",
                              fix: .continueSetup)
        }
        if status.state == .waitingForDriver {
            return StatusLine(tone: .problem,
                              message: "Duette isn't installed properly. Please run the Duette installer again.",
                              fix: nil)
        }
        if case .error = status.state {
            return StatusLine(tone: .problem, message: "Something went wrong. Duette is trying again.", fix: .tryAgain)
        }
        switch micPermission {
        case .denied:
            return StatusLine(tone: .problem, message: "Duette needs permission to use your microphone",
                              fix: .openMicrophoneSettings)
        case .notDetermined:
            return StatusLine(tone: .waiting, message: "Duette needs to ask for your microphone", fix: .allowMicrophone)
        case .granted:
            break
        }
        if status.appSilentWhilePlaying, let name = selectedAppName {
            return StatusLine(tone: .problem, message: "Duette needs permission to hear \(name)",
                              fix: .openSystemAudioSettings,
                              hint: "Scroll down to System Audio Recording Only and switch on Duette")
        }
        switch status.state {
        case .waitingForApp(let bundleID):
            let name = selectedAppName ?? AppNaming.fallbackName(bundleID)
            return StatusLine(tone: .waiting, message: "Waiting for \(name) to start", fix: nil)
        case .running(let sources):
            if status.tapError != nil {
                let name = selectedAppName ?? "the app"
                return StatusLine(tone: .waiting, message: "Duette can't hear \(name) yet", fix: .tryAgain)
            }
            switch sources {
            case .none, .appOnly:
                return StatusLine(tone: .waiting, message: "Your microphone isn't connected", fix: nil)
            case .micOnly, .both:
                return StatusLine(tone: .good, message: "Working: other apps can use Duette as a microphone", fix: nil)
            }
        case .idle, .waitingForDriver, .error:
            return StatusLine(tone: .idle, message: "Duette is paused", fix: nil)
        }
    }
}

/// Names for apps, for the lines above and the pickers.
enum AppNaming {
    /// A name for an app that is not running and not found on disk: the last part of its bundle ID,
    /// so "com.hnc.Discord" reads "Discord".
    static func fallbackName(_ bundleID: String) -> String {
        guard let last = bundleID.split(separator: ".").last, !last.isEmpty else { return "that app" }
        return String(last)
    }
}
