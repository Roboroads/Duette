import CoreAudio
import Foundation

/// What the user picked. Persisted by the app.
public struct EngineConfiguration: Equatable, Codable {
    /// The app to tap, or nil for mic only.
    public var appBundleID: String?
    public var mic: MicSelection
    /// IO buffer size of the aggregate, in frames.
    public var bufferFrameSize: UInt32

    public static let bufferFrameSizes: [UInt32] = [64, 128, 256, 512]
    public static let defaultBufferFrameSize: UInt32 = 128

    public init(appBundleID: String? = nil, mic: MicSelection = .systemDefault,
                bufferFrameSize: UInt32 = EngineConfiguration.defaultBufferFrameSize) {
        self.appBundleID = appBundleID
        self.mic = mic
        self.bufferFrameSize = bufferFrameSize
    }
}

/// What the running engine mixes.
public enum EngineSources: String, Codable, Equatable {
    case none
    case micOnly
    case appOnly
    case both

    public init(mic: Bool, app: Bool) {
        switch (mic, app) {
        case (true, true): self = .both
        case (true, false): self = .micOnly
        case (false, true): self = .appOnly
        case (false, false): self = .none
        }
    }
}

public enum EngineState: Equatable, Codable {
    /// Not started, or stopped for sleep.
    case idle
    /// The driver's sink is missing (not installed, or coreaudiod is restarting). No engine runs;
    /// it is built as soon as the sink appears.
    case waitingForDriver
    /// The selected app is not running. The engine runs with the mic meanwhile and adds the app as
    /// soon as its processes appear.
    case waitingForApp(bundleID: String)
    case running(EngineSources)
    /// Building or starting the engine failed with this status; it is retried after 1, 2, 5, 5...
    /// seconds. `attempt` counts the failures in a row.
    case error(status: OSStatus, attempt: Int)
}

/// A snapshot of the controller for the UI and diagnostics.
public struct EngineStatus: Equatable, Codable {
    public var state: EngineState = .idle
    public var sources: EngineSources = .none
    public var configuration = EngineConfiguration()
    /// The mic in use, if any.
    public var micUID: String?
    public var micName: String?
    /// PIDs of the app processes being tapped.
    public var tappedPIDs: [pid_t] = []
    /// The app is playing but its tap has delivered only exact silence for more than
    /// EngineController.silenceHintSeconds: the System Audio Recording permission is probably off.
    public var appSilentWhilePlaying = false
    /// Creating the app's tap failed; the engine runs without the app until the next rebuild.
    public var tapError: CoreAudioError?
    /// The tapped app is recording "Duette", so its callers would hear themselves. A warning
    /// only: the audio is left as it is.
    public var feedbackLoop = false
    /// The app's processes that are recording "Duette".
    public var feedbackLoopPIDs: [pid_t] = []
    /// The most recent failure, kept after recovery for diagnostics.
    public var lastError: CoreAudioError?
    /// Full teardown-and-build cycles so far.
    public var rebuildCount = 0
    public var aggregateID: AudioObjectID?
    public var layout: EngineLayout?
    public var inputLayoutMethod: LayoutMethod?
    public var outputLayoutMethod: LayoutMethod?
    public var sampleRate: Double?

    public init() {}

    /// Forgets everything about the engine that ran: what it mixed, its aggregate and layout, and
    /// the hints about it. Keeps the state, the configuration, the last error and the counters.
    mutating func clearEngineFacts() {
        sources = .none
        micUID = nil
        micName = nil
        tappedPIDs = []
        appSilentWhilePlaying = false
        tapError = nil
        feedbackLoop = false
        feedbackLoopPIDs = []
        aggregateID = nil
        layout = nil
        inputLayoutMethod = nil
        outputLayoutMethod = nil
        sampleRate = nil
    }
}

/// Runs the engine and keeps it running: builds the tap and the private aggregate, starts the
/// IOProc, and tears everything down and builds it again whenever something it depends on
/// changes. A running aggregate is never changed in place.
///
/// Rebuild triggers (each debounced by `debounceInterval`):
///  - the selected app's set of processes changes (a helper starts or exits, the app quits or
///    relaunches);
///  - the mic disappears or comes back, or the default input changes while "System default" is
///    selected;
///  - the sink appears or disappears, or coreaudiod restarts;
///  - the sample rate or stream layout of the sink or the mic changes;
///  - the system wakes from sleep (it stops on sleep);
///  - the user changes the app, the mic or the buffer size.
///
/// All work happens on the scheduler's serial context. `status` may be read from any thread.
public final class EngineController {
    public static let debounceInterval: TimeInterval = 0.25
    public static let retryDelays: [TimeInterval] = [1, 2, 5]
    public static let monitorInterval: TimeInterval = 0.5
    public static let silenceHintSeconds: Double = 3

    /// The engine. Gains, mutes, meters and the test tone are set and read on it directly.
    public let engine: MixEngine
    public let audioSystem: AudioSystem
    private let scheduler: ControlScheduler
    /// Duette's own process: never part of the tapped app, never a feedback loop.
    public let ownPID: pid_t

    /// Levels sampled every `monitorInterval`, for diagnostics.
    public let meterHistory = MeterHistory()

    /// Called on the control context after every status change. Set it before `start`.
    public var onStatusChange: ((EngineStatus) -> Void)?

    private let statusLock = NSLock()
    private var currentStatus = EngineStatus()

    // Control-context state.
    private var configuration = EngineConfiguration()
    private var started = false
    private var asleep = false
    private var session: Session?
    private var pendingRebuild: ScheduledWork?
    private var pendingRetry: ScheduledWork?
    private var monitorTimer: ScheduledWork?
    private var failures = 0

    private struct DeviceChoice: Equatable {
        var sink: AudioObjectID?
        var micUID: String?
        var micID: AudioObjectID?
    }

    private var lastAttempt = DeviceChoice()

    private struct DeviceFacts: Equatable {
        var sampleRate: Double?
        var inputs: [Int]
        var outputs: [Int]
    }

    private struct Session {
        var aggregate: AudioObjectID
        var sinkID: AudioObjectID
        var mic: AudioDeviceInfo?
        var tap: ProcessTap?
        var token: IOToken?
        var group: Set<AudioObjectID>
        var sampleRate: Double
        var facts: [AudioObjectID: DeviceFacts]
    }

    public init(audioSystem: AudioSystem, engine: MixEngine = MixEngine(),
                scheduler: ControlScheduler = QueueScheduler(),
                ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.audioSystem = audioSystem
        self.engine = engine
        self.scheduler = scheduler
        self.ownPID = ownPID
        audioSystem.eventHandler = { [weak self] event in
            guard let self else { return }
            self.scheduler.async { [weak self] in self?.handle(event) }
        }
    }

    deinit {
        // Runs on whatever thread drops the last reference; the HAL calls are thread-safe.
        if let session { tearDown(session) }
    }

    public var status: EngineStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return currentStatus
    }

    // MARK: - Commands

    /// Starts the engine with `configuration` and keeps it running until `stop`.
    public func start(_ configuration: EngineConfiguration) {
        scheduler.async { [weak self] in
            guard let self else { return }
            self.configuration = configuration
            self.started = true
            self.updateStatus { $0.configuration = configuration }
            self.cancelPending()
            self.rebuildNow()
            self.scheduleMonitor()
        }
    }

    /// Applies a new configuration; the engine is rebuilt if anything changed.
    public func update(_ configuration: EngineConfiguration) {
        scheduler.async { [weak self] in
            guard let self, configuration != self.configuration else { return }
            self.configuration = configuration
            self.updateStatus { $0.configuration = configuration }
            if self.started { self.requestRebuild() }
        }
    }

    /// Tears the engine down and builds it again (for example from a "Try again" button).
    public func rebuild() {
        scheduler.async { [weak self] in
            guard let self, self.started else { return }
            self.requestRebuild()
        }
    }

    public func stop() {
        scheduler.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.cancelPending()
            self.monitorTimer?.cancel()
            self.monitorTimer = nil
            self.teardown()
            self.failures = 0
            self.updateStatus {
                $0.state = .idle
                $0.clearEngineFacts()
            }
        }
    }

    // MARK: - Choices for the UI

    /// "System default" plus every usable input device.
    public func micChoices() -> [MicChoice] {
        DeviceCatalog.micChoices(from: audioSystem.devices())
    }

    /// Running apps, those playing audio first.
    public func appChoices() -> [AppEntry] {
        ProcessCatalog.appEntries(runningApps: audioSystem.runningApps(), processes: audioSystem.processes(),
                                  parentPID: audioSystem.parentPID, responsiblePID: audioSystem.responsiblePID,
                                  excludingPID: ownPID)
    }

    // MARK: - Events

    private func handle(_ event: AudioSystemEvent) {
        switch event {
        case .willSleep:
            asleep = true
            cancelPending()
            teardown()
            failures = 0
            updateStatus {
                $0.state = .idle
                $0.clearEngineFacts()
            }
            return
        case .didWake:
            asleep = false
            if started { requestRebuild() }
            return
        default:
            break
        }
        guard started, !asleep else { return }

        switch event {
        case .serviceRestarted:
            requestRebuild()
        case .devicesChanged, .defaultInputChanged:
            if devicesNeedRebuild() { requestRebuild() }
        case .processesChanged:
            if appProcessesChanged() { requestRebuild() }
            checkFeedbackLoop()
        case .deviceChanged(let device):
            if deviceFactsChanged(device) { requestRebuild() }
        case .overload(let device):
            if device == session?.aggregate { engine.countOverload() }
        case .inputClientsChanged:
            checkFeedbackLoop()
        case .willSleep, .didWake:
            break
        }
    }

    /// Whether the sink or the mic now differ from what the last build (successful or not) used.
    /// Comparing against the last attempt keeps the device notifications that our own aggregates
    /// cause from triggering rebuilds, including during the retry backoff.
    private func devicesNeedRebuild() -> Bool {
        currentDevices() != lastAttempt
    }

    private func currentDevices() -> DeviceChoice {
        let mic = resolveMic()
        return DeviceChoice(sink: audioSystem.deviceID(forUID: DuetteDriver.sinkUID), micUID: mic?.uid, micID: mic?.id)
    }

    private func appProcessesChanged() -> Bool {
        guard let session, configuration.appBundleID != nil else { return false }
        return Set(appProcesses().map(\.objectID)) != session.group
    }

    private func deviceFactsChanged(_ device: AudioObjectID) -> Bool {
        guard let session, let recorded = session.facts[device] else { return false }
        return facts(of: device) != recorded
    }

    // MARK: - Lookups

    private func resolveMic() -> AudioDeviceInfo? {
        DeviceCatalog.resolveMic(configuration.mic, devices: audioSystem.devices(),
                                 defaultInputUID: audioSystem.defaultInputDeviceUID())
    }

    private func appProcesses() -> [AudioProcessInfo] {
        guard let bundleID = configuration.appBundleID else { return [] }
        return ProcessCatalog.processes(of: bundleID, in: audioSystem.processes(),
                                        appPIDs: Set(audioSystem.runningApplicationPIDs(bundleID: bundleID)),
                                        parentPID: audioSystem.parentPID, responsiblePID: audioSystem.responsiblePID,
                                        excludingPID: ownPID)
    }

    private func facts(of device: AudioObjectID) -> DeviceFacts {
        DeviceFacts(sampleRate: audioSystem.nominalSampleRate(of: device),
                    inputs: audioSystem.streams(of: device, scope: kAudioObjectPropertyScopeInput).map(\.channels),
                    outputs: audioSystem.streams(of: device, scope: kAudioObjectPropertyScopeOutput).map(\.channels))
    }

    // MARK: - Build and teardown

    private func cancelPending() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        pendingRetry?.cancel()
        pendingRetry = nil
    }

    private func requestRebuild() {
        cancelPending()
        pendingRebuild = scheduler.after(Self.debounceInterval) { [weak self] in
            guard let self else { return }
            self.pendingRebuild = nil
            self.rebuildNow()
        }
    }

    private func rebuildNow() {
        teardown()
        guard started, !asleep else {
            updateStatus { $0.state = .idle }
            return
        }
        build()
    }

    private func teardown() {
        guard let session else { return }
        self.session = nil
        tearDown(session)
        audioSystem.watch(devices: [], aggregate: nil)
    }

    private func tearDown(_ session: Session) {
        if let token = session.token { audioSystem.stopIO(token) }
        audioSystem.destroyAggregate(session.aggregate)
        if let tap = session.tap { audioSystem.destroyTap(tap.id) }
    }

    private func build() {
        let configuration = self.configuration
        updateStatus { $0.rebuildCount += 1 }

        // 1. The sink (without it there is nothing to play into) and the mic.
        let mic = resolveMic()
        let sink = audioSystem.deviceID(forUID: DuetteDriver.sinkUID)
        lastAttempt = DeviceChoice(sink: sink, micUID: mic?.uid, micID: mic?.id)
        guard let sinkID = sink else {
            updateStatus {
                $0.state = .waitingForDriver
                $0.clearEngineFacts()
            }
            checkFeedbackLoop()
            return
        }

        // 2. The app.
        let group = appProcesses()
        var tap: ProcessTap?
        var tapError: CoreAudioError?
        if !group.isEmpty {
            do {
                tap = try audioSystem.createTap(TapSpec(processObjectIDs: group.map(\.objectID)))
            } catch {
                tapError = Self.coreAudioError(error, "create the app's tap")
            }
        }

        // 3. The aggregate.
        let spec = AggregateSpec(ownerPID: ownPID, sinkUID: DuetteDriver.sinkUID, micUID: mic?.uid, tapUID: tap?.uid)
        let aggregate: AudioObjectID
        do {
            aggregate = try audioSystem.createAggregate(AggregateBuilder.description(for: spec))
        } catch {
            if let tap { audioSystem.destroyTap(tap.id) }
            fail(error, "create the aggregate device")
            return
        }
        var partial = Session(aggregate: aggregate, sinkID: sinkID, mic: mic, tap: tap, token: nil,
                              group: Set(group.map(\.objectID)), sampleRate: 48000, facts: [:])
        var bufferError: CoreAudioError?
        do {
            try audioSystem.setBufferFrameSize(configuration.bufferFrameSize, of: aggregate)
        } catch {
            bufferError = Self.coreAudioError(error, "set the buffer size")
        }

        // 4. Which buffers belong to whom.
        let layout: EngineLayout
        let methods: (LayoutMethod, LayoutMethod)
        do {
            let resolved = try resolveLayout(aggregate: aggregate, sinkID: sinkID, mic: mic, tap: tap)
            partial.sampleRate = audioSystem.nominalSampleRate(of: aggregate)
                ?? audioSystem.nominalSampleRate(of: sinkID) ?? 48000
            layout = EngineLayout(input: resolved.input, output: resolved.output, sampleRate: partial.sampleRate)
            methods = (resolved.input.method, resolved.output.method)
            try engine.configure(layout)
        } catch {
            tearDown(partial)
            fail(error, "lay out the aggregate's streams")
            return
        }

        // 5. Start.
        do {
            partial.token = try audioSystem.startIO(on: aggregate, engine: engine)
        } catch {
            tearDown(partial)
            fail(error, "start the engine")
            return
        }

        var watched = [sinkID]
        if let mic { watched.append(mic.id) }
        for device in watched { partial.facts[device] = facts(of: device) }
        session = partial
        audioSystem.watch(devices: watched, aggregate: aggregate)
        failures = 0

        let sources = EngineSources(mic: mic != nil, app: tap != nil)
        let state: EngineState
        if let bundleID = configuration.appBundleID, group.isEmpty {
            state = .waitingForApp(bundleID: bundleID)
        } else {
            state = .running(sources)
        }
        updateStatus {
            $0.state = state
            $0.sources = sources
            $0.configuration = configuration
            $0.micUID = mic?.uid
            $0.micName = mic?.name
            $0.tappedPIDs = group.map(\.pid).sorted()
            $0.tapError = tapError
            if let error = tapError ?? bufferError { $0.lastError = error }
            $0.aggregateID = aggregate
            $0.layout = layout
            $0.inputLayoutMethod = methods.0
            $0.outputLayoutMethod = methods.1
            $0.sampleRate = partial.sampleRate
            $0.appSilentWhilePlaying = false
        }
        checkFeedbackLoop()
    }

    private func resolveLayout(aggregate: AudioObjectID, sinkID: AudioObjectID, mic: AudioDeviceInfo?,
                               tap: ProcessTap?) throws -> (input: StreamLayout, output: StreamLayout) {
        func members(_ scope: AudioObjectPropertyScope) -> [LayoutMember] {
            var result = [LayoutMember(role: .sink, objectID: sinkID, streams: audioSystem.streams(of: sinkID, scope: scope))]
            if let mic {
                result.append(LayoutMember(role: .mic, objectID: mic.id, streams: audioSystem.streams(of: mic.id, scope: scope)))
            }
            if let tap, scope == kAudioObjectPropertyScopeInput {
                result.append(LayoutMember(role: .tap, objectID: tap.id, streams: [StreamInfo(id: 0, channels: tap.channels)]))
            }
            return result
        }
        let inputMembers = members(kAudioObjectPropertyScopeInput)
        let outputMembers = members(kAudioObjectPropertyScopeOutput)
        let streams = audioSystem.aggregateStreams(aggregate,
                                                   expectedInputs: inputMembers.reduce(0) { $0 + $1.streams.count },
                                                   expectedOutputs: outputMembers.reduce(0) { $0 + $1.streams.count })
        for (scope, list) in [(kAudioObjectPropertyScopeInput, streams.input),
                              (kAudioObjectPropertyScopeOutput, streams.output)] {
            if let configuration = audioSystem.bufferChannels(of: aggregate, scope: scope) {
                try StreamLayoutResolver.verifyBuffers(streams: list, configuration: configuration)
            }
        }
        return (try StreamLayoutResolver.resolve(streams: streams.input, members: inputMembers),
                try StreamLayoutResolver.resolve(streams: streams.output, members: outputMembers))
    }

    private func fail(_ error: Error, _ operation: String) {
        failures += 1
        let failure = Self.coreAudioError(error, operation)
        let delay = Self.retryDelays[min(failures - 1, Self.retryDelays.count - 1)]
        let attempt = failures
        updateStatus {
            $0.state = .error(status: failure.status, attempt: attempt)
            $0.clearEngineFacts()
            $0.lastError = failure
        }
        pendingRetry = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.pendingRetry = nil
            self.rebuildNow()
        }
    }

    static func coreAudioError(_ error: Error, _ operation: String) -> CoreAudioError {
        if let error = error as? CoreAudioError { return error }
        return CoreAudioError(OSStatus(kAudioHardwareUnspecifiedError), "\(operation): \(error)")
    }

    // MARK: - Monitoring

    private func scheduleMonitor() {
        monitorTimer?.cancel()
        monitorTimer = scheduler.after(Self.monitorInterval) { [weak self] in
            guard let self, self.started else { return }
            self.monitor()
            self.scheduleMonitor()
        }
    }

    /// Warns when the tapped app records "Duette". Duette's own process does not count.
    private func checkFeedbackLoop() {
        let appPIDs = Set(appProcesses().map(\.pid))
        let looping = FeedbackLoopDetector.loopingPIDs(inputClients: audioSystem.inputClientPIDs() ?? [],
                                                       appPIDs: appPIDs, ownPID: ownPID)
        updateStatus {
            $0.feedbackLoop = !looping.isEmpty
            $0.feedbackLoopPIDs = looping
        }
    }

    private func monitor() {
        meterHistory.record(engine.meters())
        let hint = captureLooksDenied()
        if hint != status.appSilentWhilePlaying {
            updateStatus { $0.appSilentWhilePlaying = hint }
        }
    }

    /// The tap has delivered nothing but exact zeros since it started, for a while, although the
    /// app is playing. Once it has delivered sound, later silence is a quiet app, not a denial.
    private func captureLooksDenied() -> Bool {
        guard let session, session.tap != nil else { return false }
        let stats = engine.stats()
        guard !stats.tapHadAudio else { return false }
        let silentSeconds = Double(stats.tapZeroFrames) / session.sampleRate
        guard silentSeconds > Self.silenceHintSeconds else { return false }
        return audioSystem.processes().contains { session.group.contains($0.objectID) && $0.isRunningOutput }
    }

    // MARK: - Status

    private func updateStatus(_ change: (inout EngineStatus) -> Void) {
        statusLock.lock()
        var next = currentStatus
        change(&next)
        let changed = next != currentStatus
        currentStatus = next
        statusLock.unlock()
        if changed { onStatusChange?(next) }
    }
}
