import CoreAudio
@testable import DuetteAudio
import Foundation

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
    var responsible: [pid_t: pid_t] = [:]
    /// When set, what the aggregate's stream configuration claims instead of what its streams imply.
    var bufferChannelOverride: [Int]?
    var inputClients: [pid_t]? = []
    var rates: [AudioObjectID: Double] = [:]

    // Failures to hand out, first one first.
    var tapErrors: [OSStatus] = []
    var aggregateErrors: [OSStatus] = []
    var startErrors: [OSStatus] = []

    /// What a chirp through the loopback gives.
    var loopback: Result<LoopbackMeasurement, Error> = .success(
        LoopbackMeasurement(bufferFrameSize: 128, meanFrames: 272, worstFrames: 400, sampleOffset: 0,
                            confidence: 1, takes: 1))

    struct LoopbackCall: Equatable {
        var sink: AudioObjectID
        var duette: AudioObjectID
        var bufferFrameSize: UInt32
        /// IOProcs running while the probe played into the sink.
        var ioRunning: Int
    }

    private(set) var loopbackCalls: [LoopbackCall] = []

    // What happened.
    private(set) var createdAggregates: [[String: Any]] = []
    private(set) var liveAggregates: [AudioObjectID: [String: Any]] = [:]
    private(set) var destroyedAggregates: [AudioObjectID] = []
    private(set) var createdTaps: [TapSpec] = []
    private(set) var liveTaps: [AudioObjectID: ProcessTap] = [:]
    private(set) var bufferSizes: [UInt32] = []
    private(set) var startedIO: [AudioObjectID] = []
    private(set) var stoppedIO: [AudioObjectID] = []
    private(set) var watchedDevices: [AudioObjectID] = []
    private(set) var watchedAggregate: AudioObjectID?
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

    /// The mic UID in the most recent aggregate, if it has one.
    var lastMicUID: String? {
        guard let last = createdAggregates.last,
              let subdevices = last[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
              subdevices.count > 1 else { return nil }
        return subdevices[1][kAudioSubDeviceUIDKey] as? String
    }

    var lastHasTap: Bool { createdAggregates.last?[kAudioAggregateDeviceTapListKey] != nil }

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

    func responsiblePID(of pid: pid_t) -> pid_t? { responsible[pid] }

    func bufferChannels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int]? {
        guard liveAggregates[device] != nil else { return nil }
        if let bufferChannelOverride { return bufferChannelOverride }
        let streams = aggregateStreams(device, expectedInputs: 0, expectedOutputs: 0)
        return StreamLayoutResolver.impliedBufferChannels(scope == kAudioObjectPropertyScopeInput ? streams.input : streams.output)
    }

    func inputClientPIDs() -> [pid_t]? { inputClients }

    func createTap(_ spec: TapSpec) throws -> ProcessTap {
        if !tapErrors.isEmpty { throw CoreAudioError(tapErrors.removeFirst(), "create the process tap") }
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
        if !aggregateErrors.isEmpty { throw CoreAudioError(aggregateErrors.removeFirst(), "create the aggregate device") }
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
        if !startErrors.isEmpty { throw CoreAudioError(startErrors.removeFirst(), "start the engine") }
        startedIO.append(device)
        return IOToken(device: device)
    }

    func stopIO(_ token: IOToken) {
        stoppedIO.append(token.device)
    }

    func watch(devices: [AudioObjectID], aggregate: AudioObjectID?) {
        watchedDevices = devices
        watchedAggregate = aggregate
    }

    func measureLoopback(sink: AudioObjectID, duette: AudioObjectID, bufferFrameSize: UInt32,
                         sampleRate: Double) throws -> LoopbackMeasurement {
        loopbackCalls.append(LoopbackCall(sink: sink, duette: duette, bufferFrameSize: bufferFrameSize,
                                          ioRunning: startedIO.count - stoppedIO.count))
        return try loopback.get()
    }
}

/// A synthetic buffer list: one buffer per entry of `channels`, `frames` frames each, interleaved.
final class SyntheticBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(channels: [Int], frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(channels.count, 1))
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels.count)
        for (index, count) in channels.enumerated() {
            let samples = max(count * frames, 1)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            data.initialize(repeating: 0, count: samples)
            storage.append(data)
            list[index] = AudioBuffer(mNumberChannels: UInt32(count),
                                      mDataByteSize: UInt32(count * frames * MemoryLayout<Float>.size),
                                      mData: UnsafeMutableRawPointer(data))
        }
    }

    deinit {
        for data in storage { data.deallocate() }
        free(list.unsafeMutablePointer)
    }

    /// Sets every sample of the buffers in `range` to `value`.
    func fill(_ range: BufferRange, with value: Float) {
        guard range.count > 0 else { return }
        for buffer in range.first..<(range.first + range.count) {
            let count = Int(list[buffer].mNumberChannels) * frames
            storage[buffer].update(repeating: value, count: count)
        }
    }
}
