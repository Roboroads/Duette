import AppKit
import CoreAudio
import DuetteAudio
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

/// Everything AppModel needs from the system, in one place so tests can swap all of it.
struct AppServices {
    var audioSystem: AudioSystem
    var scheduler: ControlScheduler
    var permissions: PermissionProviding
    var loginItem: LoginItemControlling
    /// Whether an app with this bundle ID is installed.
    var isInstalled: (String) -> Bool
    /// The name of an app that is not running, from its bundle on disk.
    var displayName: (String) -> String?
    /// Turns the driver's own test beep on or off.
    var setDriverTone: (Bool) throws -> Void
    /// Whether the driver's test beep is on right now, or nil if there is no driver. The beep lives
    /// in the driver, so it outlives this app.
    var driverToneState: () -> Bool?
    var deviceTiming: (AudioObjectID) -> DeviceTiming
    var openURL: (URL) -> Void
    var openLoginItemsSettings: () -> Void
    /// Runs `work` on the main thread, now if this is already the main thread. Engine updates arrive
    /// on the control queue; published state changes on the main thread.
    var runOnMain: (@escaping () -> Void) -> Void
    /// Runs `work` off the main thread.
    var runInBackground: (@escaping () -> Void) -> Void
    /// Asks the user where to save a file called `suggestedName`; nil if they cancel. Main thread.
    var chooseDestination: (_ suggestedName: String) -> URL?
    /// Shows a file in Finder.
    var reveal: (URL) -> Void
    var diagnosticsExporter: DiagnosticsExporter = .live()

    static func live() -> AppServices {
        AppServices(
            audioSystem: CoreAudioSystem(),
            scheduler: QueueScheduler(),
            permissions: SystemPermissions(),
            loginItem: SystemLoginItem(),
            isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            displayName: { bundleID in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
                let bundle = Bundle(url: url)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                return name.isEmpty ? nil : name
            },
            setDriverTone: { try HAL.setDriverSelfTestTone($0) },
            driverToneState: { HAL.driverSelfTestTone() },
            deviceTiming: { DeviceTiming.read($0) },
            openURL: { NSWorkspace.shared.open($0) },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
            runOnMain: { work in
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            },
            runInBackground: { work in
                DispatchQueue.global(qos: .utility).async(execute: work)
            },
            chooseDestination: { suggestedName in
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel()
                panel.title = "Save the Duette details"
                panel.message = "Save this file, then send it to whoever is helping you."
                panel.nameFieldStringValue = suggestedName
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                return panel.runModal() == .OK ? panel.url : nil
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    }
}
