import CoreAudio

/// The facts about one audio device that the catalog, the controller and diagnostics use.
public struct AudioDeviceInfo: Equatable, Hashable, Codable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var nominalSampleRate: Double
    public var isHidden: Bool
    /// kAudioDevicePropertyTransportType, a four-character code such as 'usb ' or 'grup'.
    public var transportType: UInt32
    /// An aggregate device that only its creating process can see.
    public var isPrivateAggregate: Bool

    public init(id: AudioObjectID, uid: String, name: String, inputChannels: Int = 0, outputChannels: Int = 0,
                nominalSampleRate: Double = 48000, isHidden: Bool = false, transportType: UInt32 = 0,
                isPrivateAggregate: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isHidden = isHidden
        self.transportType = transportType
        self.isPrivateAggregate = isPrivateAggregate
    }
}

/// Which microphone the user wants.
public enum MicSelection: Equatable, Hashable, Codable {
    /// Whatever the system's default input is, followed when it changes.
    case systemDefault
    /// One device, by UID, so it is found again after it is unplugged and plugged back in.
    case device(uid: String)
}

/// One entry of the mic picker.
public struct MicChoice: Equatable, Hashable {
    public var selection: MicSelection
    public var name: String

    public init(selection: MicSelection, name: String) {
        self.selection = selection
        self.name = name
    }
}

/// Which input devices may be used as the mic.
public enum DeviceCatalog {
    public static let systemDefaultName = "System default"

    /// A device can be the mic if it has input channels and is not one of Duette's own devices:
    /// recording "Duette" into "Duette" would feed the mix back into itself.
    public static func isSelectableMic(_ device: AudioDeviceInfo) -> Bool {
        device.inputChannels > 0
            && !device.isHidden
            && device.uid != DuetteDriver.deviceUID
            && device.uid != DuetteDriver.sinkUID
            && !device.uid.hasPrefix(DuetteDriver.aggregateUIDPrefix)
            && !device.isPrivateAggregate
    }

    /// "System default" first, then every selectable device in the order the HAL lists them.
    public static func micChoices(from devices: [AudioDeviceInfo]) -> [MicChoice] {
        [MicChoice(selection: .systemDefault, name: systemDefaultName)]
            + devices.filter(isSelectableMic).map { MicChoice(selection: .device(uid: $0.uid), name: $0.name) }
    }

    /// The device to use for `selection` right now, or nil if there is none (unplugged, or the
    /// system default input is not usable, for example because it is "Duette" itself).
    public static func resolveMic(_ selection: MicSelection, devices: [AudioDeviceInfo],
                                  defaultInputUID: String?) -> AudioDeviceInfo? {
        let wanted: String?
        switch selection {
        case .systemDefault: wanted = defaultInputUID
        case .device(let uid): wanted = uid
        }
        guard let wanted else { return nil }
        return devices.first { $0.uid == wanted && isSelectableMic($0) }
    }
}
