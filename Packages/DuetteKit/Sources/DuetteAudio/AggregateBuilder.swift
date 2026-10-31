import CoreAudio
import Foundation

/// What goes into Duette's private aggregate device.
public struct AggregateSpec: Equatable {
    /// The process that owns the aggregate; it is part of the UID.
    public var ownerPID: pid_t
    /// The main and clock subdevice: the hidden "Duette Sink".
    public var sinkUID: String
    /// The mic, as a second subdevice with drift compensation, or nil for no mic.
    public var micUID: String?
    /// The app's process tap, in the tap list with drift compensation, or nil for no app.
    public var tapUID: String?
    public var name: String

    public init(ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                sinkUID: String = DuetteDriver.sinkUID,
                micUID: String? = nil,
                tapUID: String? = nil,
                name: String = "Duette Engine") {
        self.ownerPID = ownerPID
        self.sinkUID = sinkUID
        self.micUID = micUID
        self.tapUID = tapUID
        self.name = name
    }

    public var uid: String { DuetteDriver.aggregateUID(pid: ownerPID) }
}

/// Builds the description dictionary for AudioHardwareCreateAggregateDevice.
///
/// The aggregate is private (only this process sees it, and it dies with the process), not
/// stacked, and clocked by the sink. The mic and the tap are resampled to the sink's clock by the
/// aggregate's drift compensation. A running aggregate is never changed: any change means a new
/// one.
public enum AggregateBuilder {
    public static func description(for spec: AggregateSpec) -> [String: Any] {
        var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: spec.sinkUID]]
        if let mic = spec.micUID {
            subdevices.append([
                kAudioSubDeviceUIDKey: mic,
                kAudioSubDeviceDriftCompensationKey: 1,
            ])
        }
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: spec.name,
            kAudioAggregateDeviceUIDKey: spec.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: spec.sinkUID,
            kAudioAggregateDeviceClockDeviceKey: spec.sinkUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]
        if let tap = spec.tapUID {
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tap,
                kAudioSubTapDriftCompensationKey: true,
            ] as [String: Any]]
            description[kAudioAggregateDeviceTapAutoStartKey] = true
        }
        return description
    }
}
