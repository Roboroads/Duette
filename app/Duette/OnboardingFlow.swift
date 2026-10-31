import Foundation

/// Which screen of the welcome guide is showing: what Duette does, allow the microphone, allow the
/// app's sound, and a last one that says what to do in OBS or Zoom.
struct OnboardingFlow: Equatable {
    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case appSound
        case finish
    }

    /// What the microphone screen's one big button does.
    enum MicrophoneButton: Equatable {
        /// macOS has not asked yet: ask.
        case allow
        /// Allowed: on to the next screen.
        case next
        /// Refused earlier: only System Settings can change that.
        case openSettings
    }

    private(set) var step: Step

    init(step: Step = .welcome) {
        self.step = step
    }

    var count: Int { Step.allCases.count }

    /// 1-based, for "Step 2 of 4".
    var position: Int { step.rawValue + 1 }

    var isLast: Bool { step == Step.allCases.last }

    mutating func next() {
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }

    mutating func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    static func microphoneButton(for permission: PermissionState) -> MicrophoneButton {
        switch permission {
        case .notDetermined: return .allow
        case .granted: return .next
        case .denied: return .openSettings
        }
    }
}

/// The words of the guide. One title, a few plain sentences and one big button per screen.
struct OnboardingText: Equatable {
    var title: String
    var body: String
    var button: String

    static func text(for step: OnboardingFlow.Step, appName: String?) -> OnboardingText {
        switch step {
        case .welcome:
            return OnboardingText(
                title: "Welcome to Duette",
                body: "Duette mixes the sound of one app, like Discord, together with your microphone. "
                    + "Then OBS, Zoom or any recording app can pick up both at once, "
                    + "and you still hear everything in your headphones.",
                button: "Get started")
        case .microphone:
            return OnboardingText(
                title: "Let Duette use your microphone",
                body: "So the people you talk to can hear you, Duette needs your microphone. "
                    + "Your Mac will ask you to allow it. Choose OK.",
                button: "Allow microphone")
        case .appSound:
            guard let appName else {
                return OnboardingText(
                    title: "Let Duette hear your app",
                    body: "Pick the app whose sound you want to share, like Discord. "
                        + "You can change it later in the menu.",
                    button: "Continue")
            }
            return OnboardingText(
                title: "Let Duette hear \(appName)",
                body: "Duette shares the sound of \(appName). The first time, your Mac asks if Duette may record it. "
                    + "Choose Allow. You can pick a different app later from the Duette icon at the top of your screen.",
                button: "Continue")
        case .finish:
            return OnboardingText(
                title: "Now pick “Duette” as the microphone in OBS or Zoom",
                body: "Open the app you record or call with, go to its sound settings, and choose “Duette” as the microphone. "
                    + "That's all. Duette lives at the top of your screen, in the menu bar.",
                button: "Done")
        }
    }
}
