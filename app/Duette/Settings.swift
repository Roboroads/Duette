import DuetteAudio
import Foundation

/// What the app remembers between launches, in UserDefaults: the chosen app and mic, the gains and
/// mutes, the buffer size and whether the welcome guide is done.
///
/// Launch at login is not here. It is read from SMAppService every time, because the user can
/// change it in System Settings.
///
/// A version key makes later changes to the stored format safe. A missing key means the very first
/// launch. An older version is migrated one step at a time. A newer one (the user went back to an
/// older Duette) is left alone.
final class Settings {
    static let currentVersion = 1

    private enum Key {
        static let version = "settingsVersion"
        static let appBundleID = "appBundleID"
        static let micUID = "micUID"
        static let bufferFrameSize = "bufferFrameSize"
        static let onboardingDone = "onboardingDone"
        static func gain(_ source: MixSource) -> String { "gain.\(source.rawValue)" }
        static func mute(_ source: MixSource) -> String { "mute.\(source.rawValue)" }
    }

    /// Gains start at 100%.
    static let defaultGain: Float = 1

    private let defaults: UserDefaults

    /// Whether this is the first time Duette starts on this Mac (no version was stored yet). The
    /// app uses it to apply the first-run defaults once.
    let isFirstRun: Bool

    /// - Parameters:
    ///   - currentVersion: the version of the stored format this build writes.
    ///   - migrations: `migrations[v]` upgrades stored data from version `v` to `v + 1`.
    init(defaults: UserDefaults = .standard, currentVersion: Int = Settings.currentVersion,
         migrations: [Int: (UserDefaults) -> Void] = [:]) {
        self.defaults = defaults
        if let stored = (defaults.object(forKey: Key.version) as? NSNumber)?.intValue {
            isFirstRun = false
            if stored < currentVersion {
                for from in stored..<currentVersion {
                    migrations[from]?(defaults)
                    defaults.set(from + 1, forKey: Key.version)
                }
            }
        } else {
            isFirstRun = true
            defaults.set(currentVersion, forKey: Key.version)
        }
    }

    var version: Int {
        (defaults.object(forKey: Key.version) as? NSNumber)?.intValue ?? 0
    }

    /// The bundle ID of the app to share, or nil for "just my microphone".
    var appBundleID: String? {
        get { defaults.string(forKey: Key.appBundleID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.appBundleID) } else { defaults.removeObject(forKey: Key.appBundleID) }
        }
    }

    var mic: MicSelection {
        get {
            if let uid = defaults.string(forKey: Key.micUID), !uid.isEmpty { return .device(uid: uid) }
            return .systemDefault
        }
        set {
            switch newValue {
            case .systemDefault: defaults.removeObject(forKey: Key.micUID)
            case .device(let uid): defaults.set(uid, forKey: Key.micUID)
            }
        }
    }

    func gain(_ source: MixSource) -> Float {
        guard let number = defaults.object(forKey: Key.gain(source)) as? NSNumber else { return Self.defaultGain }
        return Self.clampGain(number.floatValue)
    }

    func setGain(_ gain: Float, for source: MixSource) {
        defaults.set(Self.clampGain(gain), forKey: Key.gain(source))
    }

    func isMuted(_ source: MixSource) -> Bool {
        defaults.bool(forKey: Key.mute(source))
    }

    func setMuted(_ muted: Bool, for source: MixSource) {
        defaults.set(muted, forKey: Key.mute(source))
    }

    /// One of EngineConfiguration.bufferFrameSizes; anything else reads as the default.
    var bufferFrameSize: UInt32 {
        get {
            let stored = defaults.integer(forKey: Key.bufferFrameSize)
            if let size = UInt32(exactly: stored), EngineConfiguration.bufferFrameSizes.contains(size) { return size }
            return EngineConfiguration.defaultBufferFrameSize
        }
        set {
            guard EngineConfiguration.bufferFrameSizes.contains(newValue) else { return }
            defaults.set(Int(newValue), forKey: Key.bufferFrameSize)
        }
    }

    var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    /// Gains go from 0 to MixEngine.maxGain (+6 dB). A value that is not a number becomes 100%.
    static func clampGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return defaultGain }
        return min(max(gain, 0), MixEngine.maxGain)
    }
}
