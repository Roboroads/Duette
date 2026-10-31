import CoreAudio
import Foundation

// How long sound takes through Duette: the estimate from the HAL's own figures (LatencyModel)
// and the measurement "Measure latency" makes (EngineController.measureLatency).
//
// The path, at the engine's buffer size B:
//   input:    mic or app -> the engine's IOProc call. B, plus the aggregate's input latency and
//             safety offset (the mic's own latency is part of the aggregate's).
//   loopback: the engine's call -> the call of an app reading "Duette". B plus the aggregate's
//             output latency and safety offset into "Duette Sink", then "Duette"'s latency and
//             safety offset and the reader's buffer, taken as B too.
// The loopback is what a chirp through the sink measures; the input side has no signal Duette
// could time, so it comes from the HAL.

/// The latency Duette adds, estimated from the HAL's figures.
public struct LatencyEstimate: Codable, Equatable {
    /// Into the engine.
    public var inputFrames: UInt32
    /// From the engine to an app reading "Duette" at the engine's buffer size.
    public var loopbackFrames: UInt32
    /// Both together.
    public var frames: UInt32
    public var milliseconds: Double

    public init(inputFrames: UInt32, loopbackFrames: UInt32, sampleRate: Double) {
        self.inputFrames = inputFrames
        self.loopbackFrames = loopbackFrames
        frames = inputFrames + loopbackFrames
        milliseconds = Double(frames) * 1000 / LatencyModel.rate(sampleRate)
    }
}

public enum LatencyModel {
    /// How far a measured loopback may be from the estimate and still match it.
    public static let toleranceMilliseconds = 1.0

    static func rate(_ sampleRate: Double) -> Double {
        sampleRate > 0 ? sampleRate : 48000
    }

    /// The estimate for an engine on `aggregate` and readers of "Duette" (`duette`, nil when the
    /// driver is missing). The reader's buffer is taken to be the engine's: "Duette"'s own
    /// buffer-size property is this process's setting and says nothing about other apps. The
    /// drift-compensation resampler is in no HAL property and is left out.
    ///
    /// `mic` is the mic device's own timing: its stream latency is added to the input side (the
    /// aggregate's device latency and safety offset already cover the mic's). Stream latencies of
    /// the aggregate's output and of "Duette" count on the loopback.
    public static func estimate(aggregate: DeviceTiming, duette: DeviceTiming?, mic: DeviceTiming? = nil,
                                sampleRate: Double) -> LatencyEstimate {
        let buffer = aggregate.bufferFrameSize ?? 0
        var input = buffer + (aggregate.inputLatency ?? 0) + (aggregate.inputSafetyOffset ?? 0)
        input += mic?.inputStreamLatency ?? 0
        var loopback = buffer + (aggregate.outputLatency ?? 0) + (aggregate.outputSafetyOffset ?? 0)
        loopback += aggregate.outputStreamLatency ?? 0
        if let duette {
            loopback += buffer + (duette.inputLatency ?? 0) + (duette.inputSafetyOffset ?? 0)
            loopback += duette.inputStreamLatency ?? 0
        }
        return LatencyEstimate(inputFrames: input, loopbackFrames: loopback, sampleRate: sampleRate)
    }
}

/// One chirp through "Duette Sink" into "Duette", as LoopbackProbe measured it.
public struct LoopbackMeasurement: Codable, Equatable {
    /// Of the sink's writer and of "Duette"'s reader: the engine's.
    public var bufferFrameSize: UInt32
    /// Frames from the writer's IOProc call to the reader's, mean over the chirp.
    public var meanFrames: Double
    /// The latest single frame of the chirp.
    public var worstFrames: Double
    /// Where the chirp landed in "Duette" relative to where it was written: 0 for an exact loopback.
    public var sampleOffset: Double
    /// Of the cross-correlation that found the chirp, 0..1.
    public var confidence: Double
    /// Takes it needed: a damaged one is repeated.
    public var takes: Int

    public init(bufferFrameSize: UInt32, meanFrames: Double, worstFrames: Double, sampleOffset: Double,
                confidence: Double, takes: Int) {
        self.bufferFrameSize = bufferFrameSize
        self.meanFrames = meanFrames
        self.worstFrames = worstFrames
        self.sampleOffset = sampleOffset
        self.confidence = confidence
        self.takes = takes
    }

    /// From an analysed take; nil if the chirp was not found or its latency not measured.
    public init?(result: LoopbackResult, bufferFrameSize: UInt32, takes: Int) {
        guard let offset = result.sampleOffset, let mean = result.latencyMean, let worst = result.latencyMax else {
            return nil
        }
        self.init(bufferFrameSize: bufferFrameSize, meanFrames: mean, worstFrames: worst, sampleOffset: offset,
                  confidence: result.confidence, takes: takes)
    }
}

/// What "Measure latency" found.
public struct LatencyMeasurement: Codable, Equatable {
    public var date: Date
    public var sampleRate: Double
    public var loopback: LoopbackMeasurement
    /// The HAL's figures for the same engine, as the menu shows them.
    public var estimate: LatencyEstimate
    /// What Duette adds, from the mic or the app to a reader of "Duette": the estimate's input
    /// side plus the measured loopback.
    public var totalFrames: Double
    public var totalMilliseconds: Double
    /// What Duette itself adds: the measured loopback, from the engine to an app reading "Duette".
    public var addedFrames: Double
    public var addedMilliseconds: Double
    /// Measured loopback minus the estimate's, in milliseconds.
    public var differenceMilliseconds: Double
    /// The measured loopback is within LatencyModel.toleranceMilliseconds of the estimate's.
    public var matchesEstimate: Bool

    public init(date: Date, loopback: LoopbackMeasurement, estimate: LatencyEstimate, sampleRate: Double) {
        self.date = date
        self.sampleRate = sampleRate
        self.loopback = loopback
        self.estimate = estimate
        let rate = LatencyModel.rate(sampleRate)
        totalFrames = Double(estimate.inputFrames) + loopback.meanFrames
        totalMilliseconds = totalFrames * 1000 / rate
        addedFrames = loopback.meanFrames
        addedMilliseconds = loopback.meanFrames * 1000 / rate
        differenceMilliseconds = (loopback.meanFrames - Double(estimate.loopbackFrames)) * 1000 / rate
        // In frames, so exactly one millisecond's worth still matches.
        let toleranceFrames = LatencyModel.toleranceMilliseconds * rate / 1000
        matchesEstimate = abs(loopback.meanFrames - Double(estimate.loopbackFrames)) <= toleranceFrames
    }
}

/// Why "Measure latency" has no result.
public enum LatencyMeasurementError: Error, Equatable, Codable, CustomStringConvertible {
    /// The engine is not running (setup not done, waiting for the driver, an error, asleep).
    case notRunning
    /// The engine is about to be built again (a change is waiting out its debounce).
    case restarting
    /// "Duette" is not there.
    case driverMissing
    /// The chirp never came back: nothing recorded from "Duette", or only silence (microphone
    /// permission off).
    case notHeard
    /// This audio system cannot measure (a test fake).
    case unsupported
    case failed(CoreAudioError)

    public var description: String {
        switch self {
        case .notRunning: return "the engine is not running"
        case .restarting: return "the engine is about to restart"
        case .driverMissing: return "the Duette device is missing"
        case .notHeard: return "the test chirp did not come back from Duette"
        case .unsupported: return "this audio system cannot measure"
        case .failed(let error): return "\(error)"
        }
    }
}
