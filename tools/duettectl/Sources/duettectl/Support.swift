import CoreAudio
import DuetteAudio
import DuettectlCore
import DuettectlIO
import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let toolStart = Date()

/// A progress line on stdout, with seconds since start.
func note(_ text: String) {
    print(String(format: "[%7.3f] ", Date().timeIntervalSince(toolStart)) + text)
    fflush(stdout)
}

/// What the command is doing right now, so a watchdog timeout can say where it got stuck.
enum Stage {
    private static let lock = NSLock()
    private static var current = "starting"

    static func set(_ text: String) {
        lock.lock()
        current = text
        lock.unlock()
        note("stage: \(text)")
    }

    static var value: String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// What has to be undone if the process ends early: child processes to stop, system settings to
/// put back. `defer` blocks do it on a normal exit; the watchdog's exit skips them, so it runs
/// these instead.
enum Cleanup {
    private static let lock = NSLock()
    private static var actions: [Int: (name: String, run: () -> Void)] = [:]
    private static var next = 0

    /// Registers `action`; pass the returned token to `remove` once it is done normally.
    @discardableResult
    static func add(_ name: String, _ action: @escaping () -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        actions[next] = (name, action)
        return next
    }

    static func remove(_ token: Int) {
        lock.lock()
        actions[token] = nil
        lock.unlock()
    }

    /// A child process: terminated if the watchdog fires while it runs.
    @discardableResult
    static func add(_ process: Process) -> Int {
        add("stop pid \(process.processIdentifier)") {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs everything registered, newest first, and forgets it.
    static func runAll() {
        lock.lock()
        let pending = actions.sorted { $0.key > $1.key }.map(\.value)
        actions = [:]
        lock.unlock()
        for action in pending {
            note("cleanup: \(action.name)")
            action.run()
        }
    }
}

/// Ends the process with a FAIL check if the command takes longer than `seconds`: a Core Audio
/// call that never returns (a pending permission prompt, for example) must not hang CI. Before it
/// exits it runs the Cleanup actions, for at most 5 s: one of them may block on the same stuck HAL.
enum Watchdog {
    static func arm(seconds: Double, reporter: Reporter) {
        guard seconds > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            reporter.record("watchdog", .fail, "no result after \(Int(seconds)) s", detail: "stuck at: \(Stage.value)")
            fflush(stdout)
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                Cleanup.runAll()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
            fflush(stdout)
            exit(124)
        }
    }
}

/// Polls `condition` until it holds or `timeout` seconds pass.
@discardableResult
func waitUntil(_ timeout: Double, interval: Double = 0.02, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}

func idle(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

// MARK: - Devices

enum Device {
    static let sampleRate = 48000.0

    /// The device with this UID (hidden ones included), waiting up to `timeout` for it to appear.
    static func find(uid: String, timeout: Double = 0) -> AudioObjectID? {
        var found: AudioObjectID?
        waitUntil(timeout, interval: 0.25) {
            found = HAL.deviceID(forUID: uid)
            return found != nil
        }
        return found
    }

    static func require(uid: String, timeout: Double = 10) throws -> AudioObjectID {
        guard let id = find(uid: uid, timeout: timeout) else { throw ToolError("no device with UID \(uid)") }
        return id
    }

    static func name(_ id: AudioObjectID) -> String {
        (try? AudioObject(id).getString(kAudioObjectPropertyName)) ?? "device \(id)"
    }

    static func uid(_ id: AudioObjectID) -> String? {
        try? AudioObject(id).getString(kAudioDevicePropertyDeviceUID)
    }

    static func isListed(_ id: AudioObjectID) -> Bool {
        ((try? HAL.deviceIDs()) ?? []).contains(id)
    }

    static func isHidden(_ id: AudioObjectID) -> Bool {
        ((try? AudioObject(id).get(kAudioDevicePropertyIsHidden, as: UInt32.self)) ?? 0) != 0
    }

    static func setBufferFrameSize(_ id: AudioObjectID, _ frames: UInt32) throws {
        try AudioObject(id).set(kAudioDevicePropertyBufferFrameSize, to: frames)
    }

    static func bufferFrameSize(_ id: AudioObjectID) -> UInt32? {
        try? AudioObject(id).get(kAudioDevicePropertyBufferFrameSize, as: UInt32.self)
    }

    struct Timing: CustomStringConvertible {
        var buffer: UInt32?
        var latency: UInt32?
        var safetyOffset: UInt32?
        var streamLatency: UInt32?

        var description: String {
            func text(_ value: UInt32?) -> String { value.map { String($0) } ?? "?" }
            return "buffer \(text(buffer)), latency \(text(latency)), safety offset \(text(safetyOffset)), stream latency \(text(streamLatency))"
        }
    }

    static func timing(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Timing {
        let object = AudioObject(id)
        var timing = Timing()
        timing.buffer = bufferFrameSize(id)
        timing.latency = try? object.get(kAudioDevicePropertyLatency, scope: scope, as: UInt32.self)
        timing.safetyOffset = try? object.get(kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self)
        if let streams = try? object.getArray(kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self),
           let first = streams.first {
            timing.streamLatency = try? AudioObject(first).get(kAudioStreamPropertyLatency, as: UInt32.self)
        }
        return timing
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = try? AudioObject.system.get(selector, as: AudioObjectID.self), id != 0 else { return nil }
        return id
    }

    static func setDefault(_ selector: AudioObjectPropertySelector, to id: AudioObjectID) throws {
        try AudioObject.system.set(selector, to: id)
        waitUntil(2) { defaultDevice(selector) == id }
    }

    static func nominalRate(_ id: AudioObjectID) -> Double? {
        try? AudioObject(id).get(kAudioDevicePropertyNominalSampleRate, as: Float64.self)
    }

    static func setNominalRate(_ id: AudioObjectID, _ rate: Double) throws {
        if nominalRate(id) == rate { return }
        try AudioObject(id).set(kAudioDevicePropertyNominalSampleRate, to: Float64(rate))
        guard waitUntil(3, { nominalRate(id) == rate }) else {
            throw ToolError("\(name(id)) stayed at \(nominalRate(id) ?? 0) Hz instead of \(rate) Hz")
        }
    }

    static func currentSampleTime(_ id: AudioObjectID) -> Double? {
        var stamp = AudioTimeStamp()
        stamp.mFlags = .sampleTimeValid
        guard AudioDeviceGetCurrentTime(id, &stamp) == 0 else { return nil }
        return stamp.mSampleTime
    }
}

/// Restores the system default devices it changed, when it goes away.
final class DefaultDevices {
    private var saved: [(AudioObjectPropertySelector, AudioObjectID)] = []
    private var cleanup: Int?

    func set(_ selector: AudioObjectPropertySelector, to id: AudioObjectID) throws {
        if let current = Device.defaultDevice(selector), !saved.contains(where: { $0.0 == selector }) {
            saved.append((selector, current))
            let restore = saved
            if let cleanup { Cleanup.remove(cleanup) }
            cleanup = Cleanup.add("restore the default devices") {
                for (selector, id) in restore.reversed() { try? AudioObject.system.set(selector, to: id) }
            }
        }
        try Device.setDefault(selector, to: id)
    }

    func restore() {
        for (selector, id) in saved.reversed() { try? Device.setDefault(selector, to: id) }
        saved = []
        if let cleanup { Cleanup.remove(cleanup) }
        cleanup = nil
    }

    deinit {
        restore()
    }
}

func ioBlock(_ raw: duettectl_block) -> IOBlock {
    IOBlock(sampleTime: raw.sample_time, nowSampleTime: raw.now_sample_time, nowHostTime: raw.now_host_time,
            frames: Int(raw.frames), position: raw.position)
}

// MARK: - Recorder and player

/// Records two input channels of a device (see duettectl_io.h).
final class Recorder {
    let device: AudioObjectID
    let sampleRate: Double
    private let handle: OpaquePointer
    private let blockCapacity: Int
    private var procID: AudioDeviceIOProcID?

    /// Keeps the latest `seconds` of audio.
    init(device: AudioObjectID, seconds: Double, sampleRate: Double = Device.sampleRate, firstChannel: UInt32 = 0) throws {
        let frames = max(4096, Int(seconds * sampleRate))
        let blocks = max(1024, frames / 16)
        guard let handle = duettectl_recorder_create(frames, blocks, firstChannel) else {
            throw ToolError("could not allocate a recorder for \(seconds) s")
        }
        self.device = device
        self.sampleRate = sampleRate
        self.handle = handle
        self.blockCapacity = blocks
    }

    deinit {
        stop()
        duettectl_recorder_destroy(handle)
    }

    func start() throws {
        var proc: AudioDeviceIOProcID?
        let status = duettectl_recorder_start(handle, device, &proc)
        guard status == 0, let proc else { throw CoreAudioError(status, "start recording from \(Device.name(device))") }
        procID = proc
    }

    func stop() {
        guard let procID else { return }
        _ = duettectl_io_stop(device, procID)
        self.procID = nil
    }

    var isRunning: Bool { procID != nil }
    var frames: UInt64 { duettectl_recorder_frames(handle) }
    var cycles: UInt64 { duettectl_recorder_cycles(handle) }
    var inputChannels: UInt32 { duettectl_recorder_input_channels(handle) }
    var capacity: Int { duettectl_recorder_capacity(handle) }

    @discardableResult
    func waitForFrames(_ count: UInt64, timeout: Double) -> Bool {
        waitUntil(timeout) { frames >= count }
    }

    /// Interleaved stereo frames from recording index `first`.
    func copy(from first: UInt64, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count * 2)
        let copied = out.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return duettectl_recorder_copy(handle, first, base, count)
        }
        return Array(out.prefix(copied * 2))
    }

    /// One channel (0 left, 1 right) from recording index `first`.
    func channel(_ index: Int, from first: UInt64, count: Int) -> [Float] {
        let stereo = copy(from: first, count: count)
        return stride(from: index, to: stereo.count, by: 2).map { stereo[$0] }
    }

    /// The latest `seconds` of one channel, or fewer if not recorded yet.
    func latest(seconds: Double, channel index: Int = 0) -> [Float] {
        let total = frames
        let want = UInt64(min(Double(capacity - 1024), seconds * sampleRate))
        let first = total > want ? total - want : 0
        return channel(index, from: first, count: Int(total - first))
    }

    /// Records `seconds` more and returns them (one channel), skipping `settle` seconds first.
    func take(seconds: Double, settle: Double = 0.1, channel index: Int = 0) -> [Float] {
        idle(settle)
        let first = frames
        let want = UInt64(seconds * sampleRate)
        waitForFrames(first + want, timeout: seconds + 3)
        return channel(index, from: first, count: Int(want))
    }

    func blocks() -> [IOBlock] {
        let count = cycles
        let start = count > UInt64(blockCapacity) ? count - UInt64(blockCapacity) : 0
        var result: [IOBlock] = []
        var raw = duettectl_block()
        var index = start
        while index < count {
            if duettectl_recorder_block(handle, index, &raw) { result.append(ioBlock(raw)) }
            index += 1
        }
        return result
    }
}

/// Plays into a device: silence, then (once armed) `signal`, then a tone (see duettectl_io.h).
final class Player {
    let device: AudioObjectID
    private let handle: OpaquePointer
    private static let blockCapacity = 16384
    private var procID: AudioDeviceIOProcID?

    init(device: AudioObjectID, signal: [Float], tailHz: Double = 0, tailAmplitude: Float = 0,
         sampleRate: Double = Device.sampleRate) throws {
        let capacity = Self.blockCapacity
        let created = signal.withUnsafeBufferPointer { buffer in
            duettectl_player_create(buffer.baseAddress, buffer.count, capacity)
        }
        guard let handle = created else { throw ToolError("could not allocate a player") }
        duettectl_player_set_tail(handle, tailHz, tailAmplitude, sampleRate)
        self.device = device
        self.handle = handle
    }

    deinit {
        stop()
        duettectl_player_destroy(handle)
    }

    func start() throws {
        var proc: AudioDeviceIOProcID?
        let status = duettectl_player_start(handle, device, &proc)
        guard status == 0, let proc else { throw CoreAudioError(status, "start playing into \(Device.name(device))") }
        procID = proc
    }

    func arm() {
        duettectl_player_arm(handle)
    }

    func stop() {
        guard let procID else { return }
        _ = duettectl_io_stop(device, procID)
        self.procID = nil
    }

    var cycles: UInt64 { duettectl_player_cycles(handle) }

    func blocks() -> [IOBlock] {
        let count = cycles
        let capacity = UInt64(Self.blockCapacity)
        let start = count > capacity ? count - capacity : 0
        var result: [IOBlock] = []
        var raw = duettectl_block()
        var index = start
        while index < count {
            if duettectl_player_block(handle, index, &raw) { result.append(ioBlock(raw)) }
            index += 1
        }
        return result
    }
}

// MARK: - Tone checks

extension Reporter {
    /// Checks one recording for the expected tones; one check per expectation.
    @discardableResult
    func tones(_ name: String, _ samples: [Float], sampleRate: Double = Device.sampleRate,
               expect: [ToneExpectation]) -> Bool {
        let results = ToneChecker.check(samples, sampleRate: sampleRate, expect: expect)
        let stats = SignalStats(samples)
        var all = true
        for result in results {
            let label = String(format: "%.0fhz", result.expectation.frequency)
            let value = result.measured.map { $0.description } ?? "no tone"
            let detail = "want \(result.expectation); \(samples.count) frames, peak \(Format.db(stats.peakDBFS))"
            all = check("\(name).\(label)", result.passed, value, detail: detail) && all
        }
        if let spectrum = Spectrum(samples: samples, sampleRate: sampleRate) {
            let peaks = spectrum.peaks(minimumDBFS: -70, limit: 4)
            let residual = spectrum.residualDBFS(excluding: peaks)
            note("\(name): peaks \(peaks.map(\.description).joined(separator: ", ")); residual \(Format.db(residual))")
        }
        return all
    }
}
