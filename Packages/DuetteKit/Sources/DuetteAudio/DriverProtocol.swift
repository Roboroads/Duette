import CoreAudio

/// What the Duette HAL plug-in (driver/) publishes. These values are the contract between the
/// driver and the app; they are mirrored here instead of shared, because the driver is built by
/// CMake and this package by SwiftPM. Change both sides together.
public enum DuetteDriver {
    /// UID of "Duette", the visible input-only device other apps record from.
    public static let deviceUID = "me.roboroads.duette.device"

    /// UID of "Duette Sink", the hidden output-only device the engine writes the mix to. Hidden
    /// devices are not in kAudioHardwarePropertyDevices; look it up with
    /// kAudioHardwarePropertyTranslateUIDToDevice.
    public static let sinkUID = "me.roboroads.duette.sink"

    /// 'dtst' on "Duette": UInt32, 1 while the driver plays its self-test tone instead of the
    /// loopback. Off by default and not persisted.
    public static let selfTestToneProperty = AudioObjectPropertySelector(0x6474_7374)

    /// 'dcli' on "Duette": read-only array of pid_t, the processes currently doing input IO on
    /// "Duette". The driver sends a property-changed notification when the list changes.
    public static let inputClientsProperty = AudioObjectPropertySelector(0x6463_6C69)

    /// Every private aggregate Duette builds has the UID `<prefix><pid>`.
    public static let aggregateUIDPrefix = "me.roboroads.duette.agg."

    public static func aggregateUID(pid: pid_t) -> String {
        aggregateUIDPrefix + String(pid)
    }
}
