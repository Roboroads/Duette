import AppKit
import CoreAudio
import DuetteAudio
import Foundation

// The fake AudioSystem below mirrors the one in Packages/DuetteKit/Tests. A test target cannot be
// shared between packages, so the app's tests carry their own copy that uses only DuetteKit's
// public API.

/// A scheduler with a hand-driven clock. Work runs inline on the test's thread.
final class ManualScheduler: ControlScheduler {
    private struct Timer {
        let id: Int
        let due: TimeInterval
        let work: () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var timers: [Timer] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0
    private var queue: [() -> Void] = []
    private var draining = false

    func async(_ work: @escaping () -> Void) {
        queue.append(work)
        drain()
    }

    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        nextID += 1
        let id = nextID
        timers.append(Timer(id: id, due: now + delay, work: work))
        return ScheduledWork { [weak self] in self?.cancelled.insert(id) }
    }

    /// Moves the clock forward, running every timer that comes due on the way, in order.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while true {
            timers.removeAll { cancelled.contains($0.id) }
            let due = timers.filter { $0.due <= target + 1e-9 }
            guard let next = due.min(by: { $0.due < $1.due || ($0.due == $1.due && $0.id < $1.id) }) else { break }
            timers.removeAll { $0.id == next.id }
            now = max(now, next.due)
            async(next.work)
        }
        now = target
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        while !queue.isEmpty { queue.removeFirst()() }
        draining = false
    }
}

/// An in-memory audio system. Tests change the world, then emit the event the real HAL would send.
final class FakeAudioSystem: AudioSystem {
    var eventHandler: ((AudioSystemEvent) -> Void)?

    // The world.
    var sinkPresent = true
    let sinkID: AudioObjectID = 900
    var deviceList: [AudioDeviceInfo] = []
    var deviceStreams: [AudioObjectID: (input: [StreamInfo], output: [StreamInfo])] = [:]
    var defaultInputUID: String?
    var processList: [AudioProcessInfo] = []
    var apps: [RunningApp] = []
    var parents: [pid_t: pid_t] = [:]
    var inputClients: [pid_t]? = []
    var rates: [AudioObjectID: Double] = [:]
    /// What macOS says about System Audio Recording, and the number it answered with.
    var captureAuthorization: CaptureAuthorization = .unknown
    var captureRawAnswer: Int32?
    /// What a test sound through the loopback gives.
    var loopback: Result<LoopbackMeasurement, Error> = .failure(LatencyMeasurementError.unsupported)

    struct LoopbackCall: Equatable {
        var sink: AudioObjectID
        var duette: AudioObjectID
        var bufferFrameSize: UInt32
        /// IOProcs running while the test sound played.
        var ioRunning: Int
    }

    // What happened.
    private(set) var createdAggregates: [[String: Any]] = []
    private(set) var liveAggregates: [AudioObjectID: [String: Any]] = [:]
    private(set) var destroyedAggregates: [AudioObjectID] = []
    private(set) var createdTaps: [TapSpec] = []
    private(set) var liveTaps: [AudioObjectID: ProcessTap] = [:]
    private(set) var bufferSizes: [UInt32] = []
    private(set) var startedIO: [AudioObjectID] = []
    private(set) var stoppedIO: [AudioObjectID] = []
    private(set) var loopbackCalls: [LoopbackCall] = []
    /// Called while the test sound plays.
    var onMeasure: (() -> Void)?
    private var nextID: AudioObjectID = 1000

    func emit(_ event: AudioSystemEvent) {
        eventHandler?(event)
    }

    /// Adds an input device with mono or stereo input and optional outputs.
    func addDevice(id: AudioObjectID, uid: String, name: String, inputChannels: Int, outputChannels: Int = 0) {
        deviceList.append(AudioDeviceInfo(id: id, uid: uid, name: name, inputChannels: inputChannels,
                                          outputChannels: outputChannels))
        deviceStreams[id] = (
            input: inputChannels > 0 ? [StreamInfo(id: id * 10 + 1, channels: inputChannels, owner: id)] : [],
            output: outputChannels > 0 ? [StreamInfo(id: id * 10 + 2, channels: outputChannels, owner: id)] : []
        )
    }

    func removeDevice(uid: String) {
        deviceList.removeAll { $0.uid == uid }
    }

    var ioRunning: Int { startedIO.count - stoppedIO.count }

    // MARK: AudioSystem

    func deviceID(forUID uid: String) -> AudioObjectID? {
        if uid == DuetteDriver.sinkUID { return sinkPresent ? sinkID : nil }
        return deviceList.first { $0.uid == uid }?.id
    }

    func devices() -> [AudioDeviceInfo] { deviceList }

    func defaultInputDeviceUID() -> String? { defaultInputUID }

    func nominalSampleRate(of device: AudioObjectID) -> Double? { rates[device] ?? 48000 }

    func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo] {
        let input = scope == kAudioObjectPropertyScopeInput
        if device == sinkID {
            return input ? [] : [StreamInfo(id: 901, channels: 2, owner: sinkID)]
        }
        guard deviceList.contains(where: { $0.id == device }), let streams = deviceStreams[device] else { return [] }
        return input ? streams.input : streams.output
    }

    /// Like the real HAL: new stream objects owned by the aggregate, subdevices in list order, then
    /// the taps.
    func aggregateStreams(_ aggregate: AudioObjectID, expectedInputs: Int,
                          expectedOutputs: Int) -> (input: [StreamInfo], output: [StreamInfo]) {
        guard let description = liveAggregates[aggregate] else { return ([], []) }
        var input: [StreamInfo] = []
        var output: [StreamInfo] = []
        var streamID = aggregate * 100
        func add(_ channels: Int, to list: inout [StreamInfo]) {
            streamID += 1
            list.append(StreamInfo(id: streamID, channels: channels, owner: aggregate))
        }
        let subdevices = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
        for subdevice in subdevices {
            guard let uid = subdevice[kAudioSubDeviceUIDKey] as? String, let id = deviceID(forUID: uid) else { continue }
            for stream in streams(of: id, scope: kAudioObjectPropertyScopeInput) { add(stream.channels, to: &input) }
            for stream in streams(of: id, scope: kAudioObjectPropertyScopeOutput) { add(stream.channels, to: &output) }
        }
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]] ?? []
        for entry in taps {
            guard let uid = entry[kAudioSubTapUIDKey] as? String,
                  let tap = liveTaps.values.first(where: { $0.uid == uid }) else { continue }
            add(tap.channels, to: &input)
        }
        return (input, output)
    }

    func processes() -> [AudioProcessInfo] { processList }

    func runningApps() -> [RunningApp] { apps }

    func runningApplicationPIDs(bundleID: String) -> [pid_t] {
        apps.filter { $0.bundleID == bundleID }.map(\.pid)
    }

    func parentPID(of pid: pid_t) -> pid_t? { parents[pid] }

    func inputClientPIDs() -> [pid_t]? { inputClients }

    func systemAudioCaptureAuthorization() -> CaptureAuthorization { captureAuthorization }

    func systemAudioCaptureRawAnswer() -> Int32? { captureRawAnswer }

    func createTap(_ spec: TapSpec) throws -> ProcessTap {
        createdTaps.append(spec)
        nextID += 1
        let tap = ProcessTap(id: nextID, uid: spec.uuid.uuidString, channels: 2, sampleRate: 48000)
        liveTaps[tap.id] = tap
        return tap
    }

    func destroyTap(_ tapID: AudioObjectID) {
        liveTaps[tapID] = nil
    }

    func createAggregate(_ description: [String: Any]) throws -> AudioObjectID {
        createdAggregates.append(description)
        nextID += 1
        liveAggregates[nextID] = description
        return nextID
    }

    func destroyAggregate(_ aggregate: AudioObjectID) {
        liveAggregates[aggregate] = nil
        destroyedAggregates.append(aggregate)
    }

    func setBufferFrameSize(_ frames: UInt32, of device: AudioObjectID) throws {
        bufferSizes.append(frames)
    }

    func startIO(on device: AudioObjectID, engine: MixEngine) throws -> IOToken {
        startedIO.append(device)
        return IOToken(device: device)
    }

    func stopIO(_ token: IOToken) {
        stoppedIO.append(token.device)
    }

    func watch(devices: [AudioObjectID], aggregate: AudioObjectID?) {}

    func measureLoopback(sink: AudioObjectID, duette: AudioObjectID, bufferFrameSize: UInt32,
                         sampleRate: Double) throws -> LoopbackMeasurement {
        loopbackCalls.append(LoopbackCall(sink: sink, duette: duette, bufferFrameSize: bufferFrameSize, ioRunning: ioRunning))
        onMeasure?()
        return try loopback.get()
    }
}

/// Microphone permission that the test controls.
final class FakePermissions: PermissionProviding {
    var microphone: PermissionState
    /// What a request answers with.
    var answer: PermissionState = .granted
    private(set) var requests = 0

    init(_ state: PermissionState = .granted) {
        microphone = state
    }

    func requestMicrophone(_ completion: @escaping (PermissionState) -> Void) {
        requests += 1
        microphone = answer
        completion(answer)
    }
}

/// Launch at login that the test controls.
final class FakeLoginItem: LoginItemControlling {
    struct Failure: Error {}

    var state: LoginItemState = .off
    var failing = false
    private(set) var calls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if failing { throw Failure() }
        state = enabled ? .on : .off
    }
}

/// Everything AppModel needs from the system, with the test's fakes in it.
final class World {
    static let discord = "com.hnc.Discord"
    static let music = "com.apple.Music"

    let audio = FakeAudioSystem()
    let scheduler = ManualScheduler()
    let permissions = FakePermissions()
    let loginItem = FakeLoginItem()
    let suiteName = "duette-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    var installedApps: Set<String> = []
    var openedURLs: [URL] = []
    var driverToneCalls: [Bool] = []
    var driverToneFails = false
    /// The driver's own test tone as the driver reports it; nil when there is no driver.
    var driverToneIsOn: Bool? = false
    /// Where the save panel "saves"; nil when the user cancels.
    var exportDestination: URL?
    private(set) var suggestedNames: [String] = []
    private(set) var revealedURLs: [URL] = []
    var zipFails = false
    /// A folder of its own for everything the diagnostics export writes.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("duette-world-\(UUID().uuidString)")

    private(set) var settingsPaneOpened = 0

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        audio.addDevice(id: 10, uid: "BuiltInMic", name: "MacBook Pro Microphone", inputChannels: 1)
        audio.addDevice(id: 11, uid: "USB-Mic", name: "USB Mic", inputChannels: 2, outputChannels: 2)
        audio.addDevice(id: 12, uid: DuetteDriver.deviceUID, name: "Duette", inputChannels: 2)
        audio.defaultInputUID = "BuiltInMic"
        audio.parents = [101: 100, 300: 1]
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Discord is running and playing audio from a helper.
    func launchDiscord() {
        audio.apps.append(RunningApp(bundleID: World.discord, name: "Discord", pid: 100))
        audio.processList.append(AudioProcessInfo(objectID: 201, pid: 101,
                                                  bundleID: "com.hnc.Discord.helper.Renderer", isRunningOutput: true))
    }

    func launchMusic() {
        audio.apps.append(RunningApp(bundleID: World.music, name: "Music", pid: 300))
        audio.processList.append(AudioProcessInfo(objectID: 210, pid: 300, bundleID: World.music, isRunningOutput: true))
    }

    /// Settings as the app opens them: the very first one on a fresh suite is a first run.
    func makeSettings() -> Settings {
        Settings(defaults: defaults)
    }

    /// Settings of a later launch, for tests that need stored choices: the first launch (and its
    /// first-run defaults) has happened already.
    func settingsOfAnEarlierLaunch() -> Settings {
        _ = Settings(defaults: defaults)
        return Settings(defaults: defaults)
    }

    var services: AppServices {
        AppServices(
            audioSystem: audio,
            scheduler: scheduler,
            permissions: permissions,
            loginItem: loginItem,
            isInstalled: { [unowned self] in self.installedApps.contains($0) },
            displayName: { _ in nil },
            setDriverTone: { [unowned self] on in
                self.driverToneCalls.append(on)
                if self.driverToneFails { throw FakeLoginItem.Failure() }
                self.driverToneIsOn = on
            },
            driverToneState: { [unowned self] in self.driverToneIsOn },
            deviceTiming: { _ in DeviceTiming(bufferFrameSize: 128) },
            openURL: { [unowned self] in self.openedURLs.append($0) },
            openLoginItemsSettings: { [unowned self] in self.settingsPaneOpened += 1 },
            runOnMain: { $0() },
            runInBackground: { $0() },
            chooseDestination: { [unowned self] name in
                self.suggestedNames.append(name)
                return self.exportDestination
            },
            reveal: { [unowned self] in self.revealedURLs.append($0) },
            diagnosticsExporter: DiagnosticsExporter(
                scratch: scratch,
                appPath: "/Applications/Duette.app",
                driverPath: "/Library/Audio/Plug-Ins/HAL/Duette.driver",
                appLog: { "app log" },
                runCommand: { _, _ in "ok" },
                makeZip: { [unowned self] folder, zip in
                    self.zipFails ? false : DiagnosticsExporter.zipWithDitto(folder, zip)
                }))
    }

    func makeModel(settings: Settings? = nil, onboardingDone: Bool = true) -> AppModel {
        let settings = settings ?? makeSettings()
        if onboardingDone { settings.onboardingDone = true }
        return AppModel(settings: settings, services: services)
    }

    /// Lets the controller's debounce run out.
    func settle() {
        scheduler.advance(by: EngineController.debounceInterval + 0.01)
    }
}
