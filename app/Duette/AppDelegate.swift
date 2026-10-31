import AppKit
import Foundation

/// Starts the app's model once macOS is ready, keeps a second copy of Duette from running, and
/// opens the welcome guide on the first launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created on first use. SwiftUI asks for it while it builds the menu bar item.
    lazy var model: AppModel = AppModel.live()

    private let onboarding = OnboardingWindowController()
    private let singleInstance = SingleInstanceGuard.live(
        bundleID: Bundle.main.bundleIdentifier ?? "me.roboroads.duette")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second copy hands over to the first one and quits before it does anything.
        if singleInstance.yieldToRunningInstance() {
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onShowGuide = { [weak self] in self?.showGuide() }
        model.start()
        if !model.onboardingDone { showGuide() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func showGuide() {
        onboarding.show(model: model) { [weak self] in
            self?.model.completeOnboarding()
        }
    }
}
