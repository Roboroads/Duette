import AppKit
import CoreAudio
import DuetteAudio
import Foundation
import ServiceManagement

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
    var deviceTiming: (AudioObjectID) -> DeviceTiming
    var openURL: (URL) -> Void
    var openLoginItemsSettings: () -> Void
    /// Runs `work` on the main thread, now if this is already the main thread. Engine updates arrive
    /// on the control queue; published state changes on the main thread.
    var runOnMain: (@escaping () -> Void) -> Void
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
            deviceTiming: { DeviceTiming.read($0) },
            openURL: { NSWorkspace.shared.open($0) },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
            runOnMain: { work in
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            })
    }
}
