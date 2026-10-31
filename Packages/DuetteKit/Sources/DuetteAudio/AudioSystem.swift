import AppKit
import CoreAudio
import Foundation

/// Something that changed in the audio system. The real system delivers these on its own queue;
/// EngineController moves them onto its control queue.
public enum AudioSystemEvent: Equatable {
    /// The device list changed: a device (the hidden sink included) appeared or went away.
    case devicesChanged
    case defaultInputChanged
    /// The list of Core Audio client processes changed.
    case processesChanged
    /// coreaudiod restarted (for example after a driver install): every object ID is stale.
    case serviceRestarted
    /// The sample rate, stream layout or liveness of a watched device changed.
    case deviceChanged(AudioObjectID)
    /// The watched aggregate missed an I/O deadline (kAudioDeviceProcessorOverload).
    case overload(AudioObjectID)
    /// The driver's list of processes recording "Duette" changed ('dcli').
    case inputClientsChanged
    case willSleep
    case didWake
}

/// A running IOProc, as returned by AudioSystem.startIO.
public final class IOToken {
    public let device: AudioObjectID
    let procID: AudioDeviceIOProcID?
    let engine: MixEngine?

    public init(device: AudioObjectID) {
        self.device = device
        self.procID = nil
        self.engine = nil
    }

    init(device: AudioObjectID, procID: AudioDeviceIOProcID, engine: MixEngine) {
        self.device = device
        self.procID = procID
        self.engine = engine
    }
}

/// Everything EngineController needs from Core Audio, behind a protocol so the controller can be
/// tested with a fake. CoreAudioSystem is the real one.
///
/// Calls come from the controller's control queue. None of them may be made from an I/O thread.
public protocol AudioSystem: AnyObject {
    /// Receives every event. Set once, before the first call that can cause events.
    var eventHandler: ((AudioSystemEvent) -> Void)? { get set }

    // Devices
    func deviceID(forUID uid: String) -> AudioObjectID?
    /// Every listed device. Hidden devices (the sink) are not in it.
    func devices() -> [AudioDeviceInfo]
    func defaultInputDeviceUID() -> String?
    func nominalSampleRate(of device: AudioObjectID) -> Double?
    /// The device's own streams in one scope; empty if it has none or is gone.
    func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo]
    /// The aggregate's streams, once it has filled them in: the HAL builds them shortly after the
    /// aggregate is created, so the real system waits (briefly) for the expected counts.
    func aggregateStreams(_ aggregate: AudioObjectID, expectedInputs: Int,
                          expectedOutputs: Int) -> (input: [StreamInfo], output: [StreamInfo])
    /// Channels of each buffer an IOProc on the device gets in one scope
    /// (kAudioDevicePropertyStreamConfiguration), or nil if unknown.
    func bufferChannels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]?

    // Processes
    func processes() -> [AudioProcessInfo]
    func runningApps() -> [RunningApp]
    func runningApplicationPIDs(bundleID: String) -> [pid_t]
    func parentPID(of pid: pid_t) -> pid_t?
    /// The process macOS holds responsible for `pid`, or nil if unknown.
    func responsiblePID(of pid: pid_t) -> pid_t?

    // Driver
    /// The processes recording "Duette" ('dcli'), or nil if the driver does not say.
    func inputClientPIDs() -> [pid_t]?

    // Building blocks
    func createTap(_ spec: TapSpec) throws -> ProcessTap
    func destroyTap(_ tapID: AudioObjectID)
    func createAggregate(_ description: [String: Any]) throws -> AudioObjectID
    func destroyAggregate(_ aggregate: AudioObjectID)
    func setBufferFrameSize(_ frames: UInt32, of device: AudioObjectID) throws
    func startIO(on device: AudioObjectID, engine: MixEngine) throws -> IOToken
    func stopIO(_ token: IOToken)

    /// Replaces the set of watched objects: `devices` report .deviceChanged, `aggregate` reports
    /// .overload. An empty set stops watching.
    func watch(devices: [AudioObjectID], aggregate: AudioObjectID?)
}

extension AudioSystem {
    /// Unknown by default, which skips the buffer cross-check.
    public func bufferChannels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]? { nil }

    /// Unknown by default, which skips grouping by responsible process.
    public func responsiblePID(of pid: pid_t) -> pid_t? { nil }
}

/// The real AudioSystem on top of the HAL.
public final class CoreAudioSystem: AudioSystem {
    public var eventHandler: ((AudioSystemEvent) -> Void)?

    private let queue = DispatchQueue(label: "me.roboroads.duette.audio-system")
    private var systemListeners: [PropertyListener] = []
    private var watchListeners: [PropertyListener] = []
    private var driverListener: PropertyListener?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init() {
        HAL.deliverNotificationsOnHALThread()
        let system = AudioObject.system.id
        let watched: [(AudioObjectPropertySelector, AudioSystemEvent)] = [
            (kAudioHardwarePropertyDevices, .devicesChanged),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            (kAudioHardwarePropertyProcessObjectList, .processesChanged),
            (kAudioHardwarePropertyServiceRestarted, .serviceRestarted),
        ]
        for (selector, event) in watched {
            if let listener = try? PropertyListener(objectID: system, selector: selector, queue: queue,
                                                    handler: { [weak self] in self?.deliver(event) }) {
                systemListeners.append(listener)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                     queue: nil) { [weak self] _ in self?.deliver(.willSleep) })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                     queue: nil) { [weak self] _ in self?.deliver(.didWake) })
        queue.sync { armDriverListener() }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }

    private func deliver(_ event: AudioSystemEvent) {
        // After a restart every object ID is stale, even one that comes back with the same number.
        if event == .serviceRestarted { armDriverListener(force: true) }
        if event == .devicesChanged { armDriverListener() }
        eventHandler?(event)
    }

    /// Listens to 'dcli' on "Duette", which comes and goes with the driver.
    private func armDriverListener(force: Bool = false) {
        let duette = HAL.deviceID(forUID: DuetteDriver.deviceUID)
        if !force, driverListener?.objectID == duette, duette != nil { return }
        driverListener = nil
        guard let duette else { return }
        driverListener = try? PropertyListener(objectID: duette, selector: DuetteDriver.inputClientsProperty,
                                               queue: queue, handler: { [weak self] in
                                                   self?.eventHandler?(.inputClientsChanged)
                                               })
    }

    // MARK: Devices

    public func deviceID(forUID uid: String) -> AudioObjectID? {
        HAL.deviceID(forUID: uid)
    }

    public func devices() -> [AudioDeviceInfo] {
        ((try? HAL.deviceIDs()) ?? []).compactMap { try? HAL.deviceInfo($0) }
    }

    public func defaultInputDeviceUID() -> String? {
        guard let id = HAL.defaultInputDeviceID() else { return nil }
        return try? AudioObject(id).getString(kAudioDevicePropertyDeviceUID)
    }

    public func nominalSampleRate(of device: AudioObjectID) -> Double? {
        guard let rate = try? AudioObject(device).get(kAudioDevicePropertyNominalSampleRate, as: Float64.self),
              rate > 0 else { return nil }
        return rate
    }

    public func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo] {
        (try? HAL.streams(of: device, scope: scope)) ?? []
    }

    public func aggregateStreams(_ aggregate: AudioObjectID, expectedInputs: Int,
                                 expectedOutputs: Int) -> (input: [StreamInfo], output: [StreamInfo]) {
        var input: [StreamInfo] = []
        var output: [StreamInfo] = []
        for _ in 0..<40 {
            input = streams(of: aggregate, scope: kAudioObjectPropertyScopeInput)
            output = streams(of: aggregate, scope: kAudioObjectPropertyScopeOutput)
            if input.count == expectedInputs && output.count == expectedOutputs { break }
            usleep(25_000)
        }
        return (input, output)
    }

    // MARK: Processes

    public func processes() -> [AudioProcessInfo] {
        ((try? HAL.processObjectIDs()) ?? []).compactMap(HAL.processInfo)
    }

    public func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
        }
    }

    public func runningApplicationPIDs(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    public func parentPID(of pid: pid_t) -> pid_t? {
        ProcessCatalog.systemParentPID(of: pid)
    }

    public func responsiblePID(of pid: pid_t) -> pid_t? {
        ProcessCatalog.systemResponsiblePID(of: pid)
    }

    public func bufferChannels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]? {
        try? AudioObject(device).bufferChannels(scope: scope)
    }

    // MARK: Driver

    public func inputClientPIDs() -> [pid_t]? {
        HAL.inputReaderPIDs()
    }

    // MARK: Building blocks

    public func createTap(_ spec: TapSpec) throws -> ProcessTap {
        try TapController.create(spec)
    }

    public func destroyTap(_ tapID: AudioObjectID) {
        TapController.destroy(tapID)
    }

    public func createAggregate(_ description: [String: Any]) throws -> AudioObjectID {
        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == kNoError, aggregate != 0 else { throw CoreAudioError(status, "create the aggregate device") }
        return aggregate
    }

    public func destroyAggregate(_ aggregate: AudioObjectID) {
        _ = AudioHardwareDestroyAggregateDevice(aggregate)
    }

    public func setBufferFrameSize(_ frames: UInt32, of device: AudioObjectID) throws {
        try AudioObject(device).set(kAudioDevicePropertyBufferFrameSize, to: frames)
    }

    public func startIO(on device: AudioObjectID, engine: MixEngine) throws -> IOToken {
        let procID = try engine.start(on: device)
        return IOToken(device: device, procID: procID, engine: engine)
    }

    public func stopIO(_ token: IOToken) {
        guard let procID = token.procID, let engine = token.engine else { return }
        engine.stop(on: token.device, procID: procID)
    }

    public func watch(devices: [AudioObjectID], aggregate: AudioObjectID?) {
        var listeners: [PropertyListener] = []
        let deviceSelectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyNominalSampleRate,
            kAudioDevicePropertyStreamConfiguration,
            kAudioDevicePropertyDeviceIsAlive,
        ]
        for device in devices {
            for selector in deviceSelectors {
                if let listener = try? PropertyListener(objectID: device, selector: selector,
                                                        scope: kAudioObjectPropertyScopeWildcard, queue: queue,
                                                        handler: { [weak self] in self?.eventHandler?(.deviceChanged(device)) }) {
                    listeners.append(listener)
                }
            }
        }
        if let aggregate,
           let listener = try? PropertyListener(objectID: aggregate, selector: kAudioDeviceProcessorOverload,
                                                queue: queue, handler: { [weak self] in self?.eventHandler?(.overload(aggregate)) }) {
            listeners.append(listener)
        }
        watchListeners = listeners
    }
}
