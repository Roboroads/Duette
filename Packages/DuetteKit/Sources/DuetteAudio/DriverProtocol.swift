import CoreAudio
import Foundation

/// What the Duette HAL plug-in (driver/) publishes, mirrored from driver/include/duette_driver_protocol.h.
/// The driver is built by CMake and this package by SwiftPM, so the values are copied rather than
/// shared. Change both sides together.
public enum DuetteDriver {
    /// UID of "Duette", the visible input-only device other apps record from.
    public static let deviceUID = "me.roboroads.duette.device"

    /// UID of "Duette Sink", the hidden output-only device the engine writes the mix to. Hidden
    /// devices are not in kAudioHardwarePropertyDevices; look it up with
    /// kAudioHardwarePropertyTranslateUIDToDevice.
    public static let sinkUID = "me.roboroads.duette.sink"

    /// Test devices, only in CI builds of the driver (-DDUETTE_TEST_DEVICES=ON).
    public static let testMicUID = "me.roboroads.duette.test-mic"
    public static let testSpeakerUID = "me.roboroads.duette.test-speaker"

    /// Where the installer puts the plug-in.
    public static let bundlePath = "/Library/Audio/Plug-Ins/HAL/Duette.driver"

    /// 'dtst' on "Duette": the driver's self-test tone. The value is a CFPropertyList: a CFNumber,
    /// 0 (off, the default) or 1 (on); a CFBoolean is accepted when setting. Not persisted.
    public static let selfTestToneProperty = AudioObjectPropertySelector(0x6474_7374)

    /// 'dcli' on "Duette": read-only CFArray of CFNumber (pid_t), the processes doing input IO on
    /// "Duette" right now. The driver sends a property-changed notification when it changes.
    public static let inputClientsProperty = AudioObjectPropertySelector(0x6463_6C69)

    /// Every private aggregate Duette builds has the UID `<prefix><pid>`.
    public static let aggregateUIDPrefix = "me.roboroads.duette.agg."

    public static func aggregateUID(pid: pid_t) -> String {
        aggregateUIDPrefix + String(pid)
    }

    /// The PIDs in a 'dcli' value, or nil if it is not an array.
    public static func decodeInputClients(_ value: CFTypeRef?) -> [pid_t]? {
        guard let value, let array = value as? [Any] else { return nil }
        return array.compactMap { ($0 as? NSNumber)?.int32Value }
    }

    /// The state in a 'dtst' value, or nil if it is not a number.
    public static func decodeSelfTestTone(_ value: CFTypeRef?) -> Bool? {
        guard let value, let number = value as? NSNumber else { return nil }
        return number.intValue != 0
    }
}

extension HAL {
    /// Whether the driver's self-test tone is on, or nil if the driver is not there.
    public static func driverSelfTestTone() -> Bool? {
        guard let duette = deviceID(forUID: DuetteDriver.deviceUID),
              let value = try? AudioObject(duette).getCFObject(DuetteDriver.selfTestToneProperty) else { return nil }
        return DuetteDriver.decodeSelfTestTone(value)
    }

    /// Switches the driver's self-test tone on or off.
    public static func setDriverSelfTestTone(_ on: Bool) throws {
        guard let duette = deviceID(forUID: DuetteDriver.deviceUID) else {
            throw CoreAudioError(OSStatus(kAudioHardwareBadDeviceError), "find the Duette device")
        }
        var address = AudioObject.address(DuetteDriver.selfTestToneProperty)
        var value: CFPropertyList = NSNumber(value: on ? 1 : 0)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(duette, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), pointer)
        }
        guard status == kNoError else { throw CoreAudioError(status, "set the driver's self-test tone") }
    }

    /// The processes recording "Duette" according to the driver ('dcli'), or nil if the driver is
    /// not there. The HAL starts the plug-in's IO once for all readers of a device, so a process
    /// that starts reading while another already does is missing here; see inputReaderPIDs.
    public static func driverInputClients() -> [pid_t]? {
        guard let duette = deviceID(forUID: DuetteDriver.deviceUID),
              let value = try? AudioObject(duette).getCFObject(DuetteDriver.inputClientsProperty) else { return nil }
        return DuetteDriver.decodeInputClients(value)
    }

    /// The processes whose HAL process object runs input IO on "Duette" (kAudioProcessPropertyDevices,
    /// input scope), also through an aggregate whose subdevices this process may read.
    public static func processesReadingDuette() -> [pid_t] {
        guard let duette = deviceID(forUID: DuetteDriver.deviceUID) else { return [] }
        var pids: [pid_t] = []
        for object in (try? processObjectIDs()) ?? [] {
            guard let info = processInfo(object), info.isRunningInput else { continue }
            let devices = (try? AudioObject(object).getArray(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput,
                                                             of: AudioObjectID.self)) ?? []
            let reads = devices.contains { device in
                if device == duette { return true }
                let members = (try? AudioObject(device).getCFObject(kAudioAggregateDevicePropertyFullSubDeviceList)) as? [String]
                return members?.contains(DuetteDriver.deviceUID) ?? false
            }
            if reads { pids.append(info.pid) }
        }
        return pids
    }

    /// Every process recording "Duette" that can be found: the driver's 'dcli' and the HAL's
    /// process objects together. Nil if the driver is not there.
    public static func inputReaderPIDs() -> [pid_t]? {
        guard let clients = driverInputClients() else { return nil }
        return Set(clients).union(processesReadingDuette()).sorted()
    }
}
