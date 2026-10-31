import AppKit
import Foundation

/// Starts the app's model once macOS is ready, keeps a second copy of Duette from running, opens
/// the welcome guide on the first launch, and shows a window when the user brings Duette up again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created on first use. SwiftUI asks for it while it builds the menu bar item.
    lazy var model: AppModel = AppModel.live()

    private let onboarding = OnboardingWindowController()
    private let running = RunningWindowController()
    private let singleInstance = SingleInstanceGuard.live(
        bundleID: Bundle.main.bundleIdentifier ?? "me.roboroads.duette")
    private var handoverObserver: NSObjectProtocol?

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
        // A second copy that hands over asks this one to show a window.
        handoverObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.showWindowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showWindowForUser()
        }
    }

    /// The user opened Duette again while it runs (from Finder, Spotlight or the Dock): the menu bar
    /// icon may be hidden behind the notch, so show a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindowForUser()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func showWindowForUser() {
        switch UserWindow.forReopen(onboardingDone: model.onboardingDone) {
        case .guide: showGuide()
        case .running: running.show(model: model)
        }
    }

    private func showGuide() {
        onboarding.show(model: model)
    }
}
