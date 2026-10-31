import CoreAudio
import DuetteAudio
import DuettectlCore
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

// MARK: - Recorder and player

/// The probe IOProcs from DuetteKit (duette_probe.h), which "Measure latency" runs too.
typealias Recorder = ProbeRecorder
typealias Player = ProbePlayer

extension ProbeRecorder {
    /// Records `seconds` more and returns them (one channel), skipping `settle` seconds first.
    func take(seconds: Double, settle: Double = 0.1, channel index: Int = 0) -> [Float] {
        idle(settle)
        let first = frames
        let want = UInt64(seconds * sampleRate)
        waitForFrames(first + want, timeout: seconds + 3)
        return channel(index, from: first, count: Int(want))
    }
}

// MARK: - Tone checks

extension Reporter {
    /// Checks one recording for the expected tones; one check per expectation.
    @discardableResult
    ///
    /// `damaged`: late cycles left gaps in this window. Their clicks spread the other tones around,
    /// so an absent tone cannot be judged at -90 dBFS there; it is skipped (the exact-zero checks
    /// cover the mutes).
    func tones(_ name: String, _ samples: [Float], sampleRate: Double = Device.sampleRate,
               expect: [ToneExpectation], damaged: Bool = false) -> Bool {
        let results = ToneChecker.check(samples, sampleRate: sampleRate, expect: expect)
        let stats = SignalStats(samples)
        var all = true
        for result in results {
            let label = String(format: "%.0fhz", result.expectation.frequency)
            let value = result.measured.map { $0.description } ?? "no tone"
            let detail = "want \(result.expectation); \(samples.count) frames, peak \(Format.db(stats.peakDBFS))"
            if damaged, case .below = result.expectation.level {
                skip("\(name).\(label)", value, detail: detail + "; not judged: every take of this window had a late cycle")
                continue
            }
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
