import AppKit
import SwiftUI

/// The welcome guide: what Duette does, allow the microphone, allow the app's sound, and what to
/// pick in OBS or Zoom. One title, a few plain sentences and one big button per screen.
///
/// Which screen shows lives in the model, so that closing the window can tell how far the user got.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    /// Closes the window.
    let onFinish: () -> Void

    private var flow: OnboardingFlow { model.guide }

    private var text: OnboardingText {
        OnboardingText.text(for: flow.step, appName: model.selectedAppName)
    }

    private var symbol: String {
        switch flow.step {
        case .welcome: return "waveform.circle.fill"
        case .microphone: return model.micPermission == .granted ? "checkmark.circle.fill" : "mic.circle.fill"
        case .appSound: return "speaker.wave.2.circle.fill"
        case .finish: return "checkmark.circle.fill"
        }
    }

    private var buttonTitle: String {
        guard flow.step == .microphone else { return text.button }
        switch OnboardingFlow.microphoneButton(for: model.micPermission) {
        case .allow: return text.button
        case .next: return "Continue"
        case .openSettings: return "Open Microphone Settings"
        }
    }

    var body: some View {
        OnboardingPage(
            position: flow.position,
            count: flow.count,
            symbol: symbol,
            title: text.title,
            message: text.body,
            buttonTitle: buttonTitle,
            canGoBack: flow.step != .welcome,
            onButton: primaryAction,
            onBack: { model.guideBack() }
        ) {
            extra
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch flow.step {
        case .microphone:
            if model.micPermission == .granted {
                Label("Microphone allowed", systemImage: "checkmark")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else if model.micPermission == .denied {
                VStack(spacing: 8) {
                    Text("Duette can't use your microphone yet. You can switch it on in System Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Continue without it") { model.guideNext() }
                        .controlSize(.large)
                }
            }
        case .finish:
            Toggle(isOn: Binding(get: { model.loginItem == .on || model.loginItem == .needsApproval },
                                 set: { model.setLaunchAtLogin($0) })) {
                Text("Open Duette when I log in")
            }
            .toggleStyle(.switch)
            .controlSize(.large)
        default:
            EmptyView()
        }
    }

    private func primaryAction() {
        switch flow.step {
        case .welcome:
            model.guideNext()
        case .microphone:
            switch OnboardingFlow.microphoneButton(for: model.micPermission) {
            case .allow: model.perform(.allowMicrophone)
            case .next: model.guideNext()
            case .openSettings: model.perform(.openMicrophoneSettings)
            }
        case .appSound:
            // Leaving this screen starts the engine, which is what makes macOS ask about the app's sound.
            model.guideNext()
        case .finish:
            onFinish()
        }
    }
}

/// The layout of one guide screen. It knows nothing about the model, so it can be previewed.
struct OnboardingPage<Extra: View>: View {
    let position: Int
    let count: Int
    let symbol: String
    let title: String
    let message: String
    let buttonTitle: String
    let canGoBack: Bool
    let onButton: () -> Void
    let onBack: () -> Void
    let extra: Extra

    init(position: Int, count: Int, symbol: String, title: String, message: String, buttonTitle: String,
         canGoBack: Bool, onButton: @escaping () -> Void, onBack: @escaping () -> Void,
         @ViewBuilder extra: () -> Extra) {
        self.position = position
        self.count = count
        self.symbol = symbol
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.canGoBack = canGoBack
        self.onButton = onButton
        self.onBack = onBack
        self.extra = extra()
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(1...count, id: \.self) { index in
                    Circle()
                        .fill(index == position ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(position) of \(count)")

            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            extra

            Spacer(minLength: 0)

            Button(action: onButton) {
                Text(buttonTitle)
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button("Back", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .opacity(canGoBack ? 1 : 0)
                .disabled(!canGoBack)
        }
        .padding(32)
        .frame(width: 520, height: 520)
    }
}

/// Opens the guide in its own window. A menu bar app has no window of its own to put it in.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        if let window {
            bringToFront(window)
            return
        }
        self.model = model
        model.resetGuide()
        let view = OnboardingView(model: model, onFinish: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Duette"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        bringToFront(window)
    }

    /// However it closes (the Done button or the close button), the model decides whether setup
    /// counts as done.
    func windowWillClose(_ notification: Notification) {
        window = nil
        model?.guideWindowClosed()
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// What opens when Duette is brought up again, or a second copy hands over, once setup is done: the
/// same controls as the menu, for when the menu bar icon is hidden (behind the notch, or in a
/// menu bar that is full).
struct RunningWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Duette is running in the menu bar")
                    .font(.title3.bold())
                Text("Look for the Duette icon at the top of your screen. If you can't see it, the menu bar may be full. You can use everything here too.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            MenuView(model: model)
        }
        .frame(width: 360)
    }
}

final class RunningWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            bringToFront(window)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: RunningWindowView(model: model)))
        window.title = "Duette"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
struct OnboardingPage_Previews: PreviewProvider {
    static var previews: some View {
        let text = OnboardingText.text(for: .finish, appName: "Discord")
        return OnboardingPage(
            position: 4, count: 4, symbol: "checkmark.circle.fill", title: text.title, message: text.body,
            buttonTitle: text.button, canGoBack: true, onButton: {}, onBack: {}
        ) {
            Toggle("Open Duette when I log in", isOn: .constant(true))
        }
    }
}
#endif
