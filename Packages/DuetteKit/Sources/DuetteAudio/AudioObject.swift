import CoreAudio
import Foundation

let kNoError: OSStatus = 0

/// A Core Audio call that returned an error.
public struct CoreAudioError: Error, Equatable, Codable, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String { "\(operation): \(FourCC.describe(status))" }
}

/// Four-character codes, as Core Audio uses them for selectors and error codes.
public enum FourCC {
    /// "dtst" -> 0x64747374. Only the first four bytes count.
    public static func code(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in text.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    /// 0x64747374 -> "dtst", or nil if any byte is not printable ASCII.
    public static func string(_ value: UInt32) -> String? {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "'nope' (1852797029)" for four-character codes, the plain number otherwise.
    public static func describe(_ status: OSStatus) -> String {
        if status == 0 { return "no error" }
        if let text = string(UInt32(bitPattern: status)) { return "'\(text)' (\(status))" }
        return String(status)
    }
}

/// Typed access to the properties of one Core Audio object.
///
/// Every call goes straight to the HAL; nothing is cached. Use it from the control queue, never
/// from an I/O thread.
public struct AudioObject: Hashable, CustomStringConvertible {
    public let id: AudioObjectID

    public init(_ id: AudioObjectID) {
        self.id = id
    }

    public static let system = AudioObject(AudioObjectID(kAudioObjectSystemObject))

    public var description: String { "AudioObject(\(id))" }

    public static func address(_ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func name(_ selector: AudioObjectPropertySelector) -> String {
        FourCC.string(selector).map { "'\($0)'" } ?? String(selector)
    }

    public func has(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope)
        return AudioObjectHasProperty(id, &address) == true
    }

    public func dataSize(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var address = Self.address(selector, scope)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == kNoError else {
            throw CoreAudioError(status, "size of \(Self.name(selector)) on object \(id)")
        }
        return size
    }

    /// Reads a fixed-size value (an integer, a Float64, an AudioStreamBasicDescription...).
    public func get<T>(_ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                       as type: T.Type) throws -> T {
        var address = Self.address(selector, scope, element)
        let byteCount = max(MemoryLayout<T>.size, 1)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
        guard status == kNoError else {
            throw CoreAudioError(status, "get \(Self.name(selector)) on object \(id)")
        }
        return raw.load(as: T.self)
    }

    /// Reads a property whose value is an array of fixed-size values.
    public func getArray<T>(_ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                            of type: T.Type) throws -> [T] {
        var address = Self.address(selector, scope, element)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == kNoError else {
            throw CoreAudioError(status, "size of \(Self.name(selector)) on object \(id)")
        }
        let stride = MemoryLayout<T>.stride
        guard size > 0, stride > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
        guard status == kNoError else {
            throw CoreAudioError(status, "get \(Self.name(selector)) on object \(id)")
        }
        let count = Int(size) / stride
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Reads a CFString property.
    public func getString(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        guard let value = try getCFObject(selector, scope: scope), let string = value as? String else {
            throw CoreAudioError(OSStatus(kAudioHardwareUnspecifiedError),
                                 "\(Self.name(selector)) on object \(id) is not a string")
        }
        return string
    }

    /// Reads a property whose value is a Core Foundation object (CFString, CFDictionary, ...).
    public func getCFObject(_ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> CFTypeRef? {
        var address = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == kNoError else {
            throw CoreAudioError(status, "get \(Self.name(selector)) on object \(id)")
        }
        return value?.takeRetainedValue()
    }

    /// Reads a CFDictionary property as a Swift dictionary.
    public func getDictionary(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [String: Any] {
        guard let value = try getCFObject(selector, scope: scope),
              let dictionary = value as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    /// Writes a fixed-size value.
    public func set<T>(_ selector: AudioObjectPropertySelector, to value: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws {
        var address = Self.address(selector, scope, element)
        let status = withUnsafeBytes(of: value) { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(kAudioHardwareBadPropertySizeError) }
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(bytes.count), base)
        }
        guard status == kNoError else {
            throw CoreAudioError(status, "set \(Self.name(selector)) on object \(id)")
        }
    }

    /// Channels of each buffer an IOProc on this device gets in `scope`
    /// (kAudioDevicePropertyStreamConfiguration).
    public func bufferChannels(scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == kNoError else {
            throw CoreAudioError(status, "size of the stream configuration of device \(id)")
        }
        guard size >= UInt32(MemoryLayout<UInt32>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
        guard status == kNoError else {
            throw CoreAudioError(status, "stream configuration of device \(id)")
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}

/// A property listener that stays registered until it is cancelled or released.
public final class PropertyListener {
    public let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    /// Calls `handler` on `queue` whenever the property changes.
    public init(objectID: AudioObjectID,
                selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                queue: DispatchQueue,
                handler: @escaping () -> Void) throws {
        self.objectID = objectID
        self.address = AudioObject.address(selector, scope, element)
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == kNoError else {
            throw CoreAudioError(status, "listen to \(AudioObject.name(selector)) on object \(objectID)")
        }
        active = true
    }

    public func cancel() {
        guard active else { return }
        active = false
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit {
        cancel()
    }
}

/// System-wide lookups on the HAL.
public enum HAL {
    /// Makes the HAL deliver property notifications on its own thread instead of the main run
    /// loop (kAudioHardwarePropertyRunLoop = NULL). Needed by anything that does not run the main
    /// run loop, such as a command-line tool or a test; harmless in an app.
    public static func deliverNotificationsOnHALThread() {
        var address = AudioObject.address(kAudioHardwarePropertyRunLoop)
        var runLoop: CFRunLoop? = nil
        _ = withUnsafePointer(to: &runLoop) { pointer in
            AudioObjectSetPropertyData(AudioObject.system.id, &address, 0, nil,
                                       UInt32(MemoryLayout<CFRunLoop?>.size), pointer)
        }
    }

    /// Every device in kAudioHardwarePropertyDevices. Hidden devices are not in it.
    public static func deviceIDs() throws -> [AudioObjectID] {
        try AudioObject.system.getArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    /// The device with this UID, including hidden ones, or nil.
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObject.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier: CFString = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObject.system.id, &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == kNoError, device != 0 else { return nil }
        return device
    }

    public static func defaultInputDeviceID() -> AudioObjectID? {
        guard let id = try? AudioObject.system.get(kAudioHardwarePropertyDefaultInputDevice,
                                                    as: AudioObjectID.self),
              id != 0 else { return nil }
        return id
    }

    /// Reads the facts about a device that the catalog and diagnostics need.
    public static func deviceInfo(_ id: AudioObjectID) throws -> AudioDeviceInfo {
        let object = AudioObject(id)
        let uid = try object.getString(kAudioDevicePropertyDeviceUID)
        let name = (try? object.getString(kAudioObjectPropertyName)) ?? uid
        let inputs = (try? object.bufferChannels(scope: kAudioObjectPropertyScopeInput))?.reduce(0, +) ?? 0
        let outputs = (try? object.bufferChannels(scope: kAudioObjectPropertyScopeOutput))?.reduce(0, +) ?? 0
        let rate = (try? object.get(kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 0
        let hidden = (try? object.get(kAudioDevicePropertyIsHidden, as: UInt32.self)) ?? 0
        let transport = (try? object.get(kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
        var isPrivateAggregate = false
        if transport == UInt32(kAudioDeviceTransportTypeAggregate),
           let composition = try? object.getDictionary(kAudioAggregateDevicePropertyComposition) {
            isPrivateAggregate = (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
        }
        return AudioDeviceInfo(id: id, uid: uid, name: name, inputChannels: inputs, outputChannels: outputs,
                               nominalSampleRate: rate, isHidden: hidden != 0, transportType: transport,
                               isPrivateAggregate: isPrivateAggregate)
    }

    /// Every process object: the processes that are Core Audio clients right now.
    public static func processObjectIDs() throws -> [AudioObjectID] {
        try AudioObject.system.getArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    /// PID, bundle ID and running state of a process object, or nil if it is gone.
    public static func processInfo(_ id: AudioObjectID) -> AudioProcessInfo? {
        let object = AudioObject(id)
        guard let pid = try? object.get(kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
        let bundleID = (try? object.getString(kAudioProcessPropertyBundleID)) ?? ""
        let output = (try? object.get(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
        let input = (try? object.get(kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0
        return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundleID,
                                isRunningOutput: output != 0, isRunningInput: input != 0)
    }

    /// The process object of `pid`, or nil if the process is not a Core Audio client.
    public static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObject.system.id, &address, UInt32(MemoryLayout<pid_t>.size),
                                                &qualifier, &size, &object)
        guard status == kNoError, object != 0 else { return nil }
        return object
    }

    /// The device's streams in `scope`, with format and owner, in the order the HAL lists them.
    public static func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [StreamInfo] {
        let ids = try AudioObject(device).getArray(kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self)
        return ids.map { (streamID: AudioObjectID) -> StreamInfo in
            let object = AudioObject(streamID)
            let format = try? object.get(kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
            let channels = Int(format?.mChannelsPerFrame ?? 0)
            let flags = format?.mFormatFlags ?? 0
            let nonInterleaved = (flags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved)) != 0
            let owner = (try? object.get(kAudioObjectPropertyOwner, as: AudioObjectID.self)) ?? 0
            return StreamInfo(id: streamID, channels: channels, buffers: nonInterleaved ? max(channels, 1) : 1,
                              owner: owner)
        }
    }
}
