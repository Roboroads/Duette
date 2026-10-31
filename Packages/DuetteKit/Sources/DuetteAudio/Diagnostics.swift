import CoreAudio
import Darwin
import Foundation

/// Meter readings over time, so diagnostics can show the range of the last minute.
public final class MeterHistory {
    /// Two minutes at the controller's monitor interval.
    public static let capacity = 240

    private struct Sample {
        let time: Date
        let meters: Meters
    }

    private let lock = NSLock()
    private var samples: [Sample] = []

    public init() {}

    public func record(_ meters: Meters, at time: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(Sample(time: time, meters: meters))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// Minimum and maximum of every level over the last `window` seconds.
    public func summary(window: TimeInterval = 60, now: Date = Date()) -> MeterSummary {
        lock.lock()
        let recent = samples.filter { now.timeIntervalSince($0.time) <= window }.map { $0.meters }
        lock.unlock()
        return MeterSummary(recent)
    }
}

public struct LevelRange: Codable, Equatable {
    public var minPeak: Float
    public var maxPeak: Float
    public var minRMS: Float
    public var maxRMS: Float

    init?(_ levels: [Level]) {
        guard let first = levels.first else { return nil }
        minPeak = first.peak
        maxPeak = first.peak
        minRMS = first.rms
        maxRMS = first.rms
        for level in levels.dropFirst() {
            minPeak = min(minPeak, level.peak)
            maxPeak = max(maxPeak, level.peak)
            minRMS = min(minRMS, level.rms)
            maxRMS = max(maxRMS, level.rms)
        }
    }
}

public struct MeterSummary: Codable, Equatable {
    public var samples: Int
    public var app: LevelRange?
    public var mic: LevelRange?
    public var output: LevelRange?

    init(_ meters: [Meters]) {
        samples = meters.count
        app = LevelRange(meters.map { $0.app })
        mic = LevelRange(meters.map { $0.mic })
        output = LevelRange(meters.map { $0.output })
    }
}

/// The timing properties of a device, in frames.
public struct DeviceTiming: Codable, Equatable {
    public var bufferFrameSize: UInt32?
    public var inputLatency: UInt32?
    public var outputLatency: UInt32?
    public var inputSafetyOffset: UInt32?
    public var outputSafetyOffset: UInt32?
    /// kAudioStreamPropertyLatency of the device's first stream in each scope: latency on top of
    /// the device's own.
    public var inputStreamLatency: UInt32?
    public var outputStreamLatency: UInt32?

    public init(bufferFrameSize: UInt32? = nil, inputLatency: UInt32? = nil, outputLatency: UInt32? = nil,
                inputSafetyOffset: UInt32? = nil, outputSafetyOffset: UInt32? = nil,
                inputStreamLatency: UInt32? = nil, outputStreamLatency: UInt32? = nil) {
        self.bufferFrameSize = bufferFrameSize
        self.inputLatency = inputLatency
        self.outputLatency = outputLatency
        self.inputSafetyOffset = inputSafetyOffset
        self.outputSafetyOffset = outputSafetyOffset
        self.inputStreamLatency = inputStreamLatency
        self.outputStreamLatency = outputStreamLatency
    }

    /// Reads the device's buffer size, latencies and safety offsets from the HAL.
    public static func read(_ device: AudioObjectID) -> DeviceTiming {
        let object = AudioObject(device)
        func value(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
            try? object.get(selector, scope: scope, as: UInt32.self)
        }
        func streamLatency(_ scope: AudioObjectPropertyScope) -> UInt32? {
            guard let stream = (try? object.getArray(kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self))?.first
            else { return nil }
            return try? AudioObject(stream).get(kAudioStreamPropertyLatency, as: UInt32.self)
        }
        return DeviceTiming(
            bufferFrameSize: value(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputLatency: value(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
            outputLatency: value(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
            inputSafetyOffset: value(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
            outputSafetyOffset: value(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
            inputStreamLatency: streamLatency(kAudioObjectPropertyScopeInput),
            outputStreamLatency: streamLatency(kAudioObjectPropertyScopeOutput))
    }
}

/// Everything "Export Diagnostics..." writes into diagnostics.json.
public struct DiagnosticsReport: Codable {
    public struct Software: Codable {
        public var appVersion: String?
        public var driverVersion: String?
        public var macOS: String
        public var hardwareModel: String
        public var processID: pid_t
    }

    public struct Device: Codable {
        public var info: AudioDeviceInfo
        public var timing: DeviceTiming
    }

    public struct Driver: Codable {
        public var installed: Bool
        public var deviceID: AudioObjectID?
        public var sinkID: AudioObjectID?
        public var selfTestTone: Bool?
        /// 'dcli': the processes recording "Duette".
        public var inputClients: [pid_t]?
        public var deviceTiming: DeviceTiming?
        public var sinkTiming: DeviceTiming?
    }

    public struct Engine: Codable {
        public var status: EngineStatus
        public var stats: EngineStats
        public var gains: [String: Float]
        public var mutes: [String: Bool]
        public var testTone: Bool
        public var aggregateTiming: DeviceTiming?
        public var estimatedLatency: LatencyEstimate?
        /// The last "Measure latency" result, if there was one: what Duette adds, in milliseconds.
        public var measuredLatencyMilliseconds: Double?
        /// The whole of it: the measured loopback, the HAL's estimate and how far apart they are.
        public var measuredLatency: LatencyMeasurement?
        /// Meter range over the last 60 seconds.
        public var meters: MeterSummary
    }

    public var generatedAt: Date
    public var software: Software
    /// Filled in by the app (microphone, system audio recording), which owns those APIs.
    public var permissions: [String: String]
    public var devices: [Device]
    public var driver: Driver
    public var selectedApp: String?
    public var selectedAppProcesses: [AudioProcessInfo]
    public var engine: Engine?
    /// Results of the last self-tests, as the app recorded them.
    public var selfTests: [String: String]
}

/// Gathers a DiagnosticsReport from the audio system and the engine controller.
public final class DiagnosticsCollector {
    public let audioSystem: AudioSystem
    public let controller: EngineController?
    private let timing: (AudioObjectID) -> DeviceTiming
    private let selfTestTone: () -> Bool?

    public init(audioSystem: AudioSystem, controller: EngineController?,
                timing: @escaping (AudioObjectID) -> DeviceTiming = DeviceTiming.read,
                selfTestTone: @escaping () -> Bool? = HAL.driverSelfTestTone) {
        self.audioSystem = audioSystem
        self.controller = controller
        self.timing = timing
        self.selfTestTone = selfTestTone
    }

    public func collect(permissions: [String: String] = [:], selfTests: [String: String] = [:],
                        now: Date = Date()) -> DiagnosticsReport {
        let deviceID = audioSystem.deviceID(forUID: DuetteDriver.deviceUID)
        let sinkID = audioSystem.deviceID(forUID: DuetteDriver.sinkUID)
        let driver = DiagnosticsReport.Driver(
            installed: deviceID != nil || sinkID != nil,
            deviceID: deviceID,
            sinkID: sinkID,
            selfTestTone: deviceID != nil ? selfTestTone() : nil,
            inputClients: audioSystem.inputClientPIDs(),
            deviceTiming: deviceID.map(timing),
            sinkTiming: sinkID.map(timing))

        let status = controller?.status
        let selectedApp = status?.configuration.appBundleID
        var appProcesses: [AudioProcessInfo] = []
        if let selectedApp {
            appProcesses = ProcessCatalog.processes(
                of: selectedApp, in: audioSystem.processes(),
                appPIDs: Set(audioSystem.runningApplicationPIDs(bundleID: selectedApp)),
                parentPID: audioSystem.parentPID, responsiblePID: audioSystem.responsiblePID,
                excludingPID: controller?.ownPID)
        }

        var engineReport: DiagnosticsReport.Engine?
        if let controller, let status {
            let engine = controller.engine
            let aggregateTiming = status.aggregateID.map(timing)
            let micTiming = status.micUID.flatMap { audioSystem.deviceID(forUID: $0) }.map(timing)
            let estimate = aggregateTiming.map {
                LatencyModel.estimate(aggregate: $0, duette: driver.deviceTiming, mic: micTiming,
                                      sampleRate: status.sampleRate ?? 48000)
            }
            let measured = controller.latestLatencyMeasurement
            var gains: [String: Float] = [:]
            var mutes: [String: Bool] = [:]
            for source in MixSource.allCases {
                gains[source.rawValue] = engine.gain(for: source)
                mutes[source.rawValue] = engine.isMuted(source)
            }
            engineReport = DiagnosticsReport.Engine(
                status: status, stats: engine.stats(), gains: gains, mutes: mutes, testTone: engine.testTone,
                aggregateTiming: aggregateTiming, estimatedLatency: estimate,
                measuredLatencyMilliseconds: measured?.totalMilliseconds, measuredLatency: measured,
                meters: controller.meterHistory.summary(window: 60, now: now))
        }

        let software = DiagnosticsReport.Software(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            driverVersion: Bundle(path: DuetteDriver.bundlePath)?.infoDictionary?["CFBundleShortVersionString"] as? String,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModel(),
            processID: ProcessInfo.processInfo.processIdentifier)

        return DiagnosticsReport(
            generatedAt: now, software: software, permissions: permissions,
            devices: audioSystem.devices().map { DiagnosticsReport.Device(info: $0, timing: timing($0.id)) },
            driver: driver, selectedApp: selectedApp, selectedAppProcesses: appProcesses,
            engine: engineReport, selfTests: selfTests)
    }

    /// The report with `measuredLatencyMilliseconds` in its engine section, as before
    /// EngineController kept the latest "Measure latency" itself.
    @available(*, deprecated, message: "collect(permissions:selfTests:now:) takes the latest measurement from the controller")
    public func collect(permissions: [String: String] = [:], selfTests: [String: String] = [:],
                        measuredLatencyMilliseconds: Double?, now: Date = Date()) -> DiagnosticsReport {
        var report = collect(permissions: permissions, selfTests: selfTests, now: now)
        if let measuredLatencyMilliseconds { report.engine?.measuredLatencyMilliseconds = measuredLatencyMilliseconds }
        return report
    }

    /// diagnostics.json: pretty-printed, keys sorted, ISO 8601 dates.
    public static func encode(_ report: DiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                      negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(report)
    }

    /// sysctl hw.model, for example "Mac14,2".
    public static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }
}
