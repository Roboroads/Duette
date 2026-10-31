import CoreAudio
import Foundation

/// What to tap: the stereo mixdown of a set of process objects.
public struct TapSpec: Equatable {
    public var processObjectIDs: [AudioObjectID]
    public var name: String
    /// Becomes the tap's UID, which the aggregate's tap list refers to.
    public var uuid: UUID

    public init(processObjectIDs: [AudioObjectID], name: String = "Duette app tap", uuid: UUID = UUID()) {
        self.processObjectIDs = processObjectIDs
        self.name = name
        self.uuid = uuid
    }
}

/// A process tap that exists in the HAL.
public struct ProcessTap: Equatable, Codable {
    public var id: AudioObjectID
    public var uid: String
    /// From kAudioTapPropertyFormat; 2 for a stereo mixdown.
    public var channels: Int
    public var sampleRate: Double

    public init(id: AudioObjectID, uid: String, channels: Int, sampleRate: Double) {
        self.id = id
        self.uid = uid
        self.channels = channels
        self.sampleRate = sampleRate
    }
}

/// Creates and destroys process taps.
///
/// The tap is a stereo mixdown of the app's processes. It does not mute them (the user keeps
/// hearing the app) and it is private to this process. The first time a tap delivers audio,
/// macOS asks for the "System Audio Recording" permission; when it is denied, the tap delivers
/// silence.
public enum TapController {
    public static func makeDescription(_ spec: TapSpec) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: tapProcessList(spec.processObjectIDs))
        description.uuid = spec.uuid
        description.name = spec.name
        description.muteBehavior = .unmuted
        description.isPrivate = true
        return description
    }

    public static func create(_ spec: TapSpec) throws -> ProcessTap {
        try create(makeDescription(spec))
    }

    public static func create(_ description: CATapDescription) throws -> ProcessTap {
        var tapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == kNoError, tapID != 0 else {
            throw CoreAudioError(status, "create the process tap")
        }
        let object = AudioObject(tapID)
        let uid = (try? object.getString(kAudioTapPropertyUID)) ?? description.uuid.uuidString
        let format = try? object.get(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        return ProcessTap(id: tapID, uid: uid, channels: Int(format?.mChannelsPerFrame ?? 2),
                          sampleRate: format?.mSampleRate ?? 0)
    }

    @discardableResult
    public static func destroy(_ tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// CATapDescription's initializer takes NSArray<NSNumber *>. These two overloads let the compiler
// pick whichever element type the SDK imports it as.
func tapProcessList(_ ids: [AudioObjectID]) -> [NSNumber] { ids.map { NSNumber(value: $0) } }
func tapProcessList(_ ids: [AudioObjectID]) -> [AudioObjectID] { ids }
