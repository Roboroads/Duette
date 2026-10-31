@testable import DuetteAudio
import XCTest

final class LoopbackAnalysisTests: XCTestCase {
    func testCoreEstimatorFindsADelayedChirp() {
        let chirp = Chirp.make(sampleRate: 48000, startHz: 200, endHz: 12000, frames: 2400)
        XCTAssertEqual(chirp.count, 2400)
        XCTAssertEqual(chirp.map { abs($0) }.max() ?? 0, 0.5, accuracy: 0.01)
        for delay in [0, 37, 480, 3000] {
            var recording = [Float](repeating: 0, count: delay) + chirp + [Float](repeating: 0, count: 4000 - delay)
            for i in recording.indices { recording[i] += 0.01 * Float(sin(Double(i) * 1.7)) }
            let estimate = LagEstimator.estimate(reference: chirp, recording: recording, maxLagFrames: 4000)
            XCTAssertEqual(estimate.lagFrames, delay)
            XCTAssertGreaterThan(estimate.confidence, 0.9)
        }
        XCTAssertEqual(LagEstimator.estimate(reference: [], recording: chirp, maxLagFrames: 10).confidence, 0)
        XCTAssertEqual(Chirp.make(sampleRate: 48000, startHz: 200, endHz: 12000, frames: 0), [])
    }

    /// A synthetic run on a shared clock: the writer is called one buffer ahead of its output
    /// time, the reader one buffer plus its 16-frame safety offset after its input time, and the
    /// loopback is exact in sample time.
    struct Run {
        let buffer = 128
        let chirp = Chirp.make(sampleRate: 48000, startHz: 200, endHz: 12000, frames: 2400)
        var writer: [IOBlock] = []
        var reader: [IOBlock] = []
        var recording: [Float] = []
        var chirpSinkTime = 0.0
        var writerEnd = 0.0

        /// `offset`: where the chirp lands in "Duette" relative to where it was written.
        /// `staleAfterStop`: frames of sound "Duette" keeps playing after the writer stops.
        init(offset: Int = 0, staleAfterStop: Int = 0, readerPhase: Int = 0) {
            let writerStart = 20_000.0
            let armedBlock = 5
            let playedBlocks = 40
            for i in 0..<(armedBlock + playedBlocks) {
                let time = writerStart + Double(i * buffer)
                let position: Int64 = i < armedBlock ? -1 : Int64((i - armedBlock) * buffer)
                writer.append(IOBlock(sampleTime: time, nowSampleTime: time - Double(buffer), frames: buffer, position: position))
            }
            let chirpStart = writerStart + Double(armedBlock * buffer)
            let end = writerStart + Double((armedBlock + playedBlocks) * buffer)
            let signal = chirp
            chirpSinkTime = chirpStart
            writerEnd = end

            // What the sink got, by sink sample time: the chirp, then a tone.
            func written(_ time: Double) -> Float {
                guard time >= chirpStart, time < end else { return 0 }
                let p = Int(time - chirpStart)
                return p < signal.count ? signal[p] : Float(0.5 * sin(Double(p) * 0.13) + 0.25)
            }
            // On the writer's cycle grid (20000 - 8 * 128), shifted by `readerPhase`.
            let readerStart = 18_976.0 + Double(readerPhase)
            for i in 0..<70 {
                let time = readerStart + Double(i * buffer)
                reader.append(IOBlock(sampleTime: time, nowSampleTime: time + Double(buffer + 16), frames: buffer,
                                      position: Int64(i * buffer)))
                for f in 0..<buffer {
                    let t = time + Double(f) - Double(offset)
                    var sample = written(t)
                    if sample == 0, staleAfterStop > 0, t >= end, t < end + Double(staleAfterStop) { sample = 0.1 }
                    recording.append(sample)
                }
            }
        }

        func analyze() -> LoopbackResult? {
            LoopbackAnalysis.analyze(chirp: chirp, writer: writer, reader: reader, recording: recording, bufferFrames: buffer)
        }
    }

    func testExactLoopbackHasNoOffsetAndTwoBuffersOfLatency() throws {
        let run = Run()
        let result = try XCTUnwrap(run.analyze())
        XCTAssertEqual(result.chirpSinkTime, run.chirpSinkTime)
        XCTAssertEqual(result.sampleOffset, 0)
        XCTAssertGreaterThan(result.confidence, 0.99)
        // Written at sink time t by the call at t - 128 (block start), read by the call at
        // t + 128 + 16: 2 buffers + the safety offset.
        XCTAssertEqual(result.latencyMax, 272)
        XCTAssertEqual(result.latencyMean, 272)
        XCTAssertEqual(result.writerEnd, run.writerEnd)
        XCTAssertNotNil(result.silenceDelay)
        XCTAssertLessThanOrEqual(result.silenceDelay ?? .infinity, 0)
        XCTAssertEqual(result.nonZeroAfterStop, 0)
        XCTAssertGreaterThan(result.observedAfterStop, 1000)
    }

    func testReaderOutOfPhaseWithTheWriter() throws {
        // Reader cycles start 64 frames into the writer's: half the frames wait half a buffer less.
        let result = try XCTUnwrap(Run(readerPhase: 64).analyze())
        XCTAssertEqual(result.sampleOffset, 0)
        XCTAssertEqual(result.latencyMax, 272 + 64)
        XCTAssertEqual(result.latencyMean ?? 0, 272, accuracy: 1)
    }

    func testAShiftedLoopbackIsReported() throws {
        let result = try XCTUnwrap(Run(offset: 5).analyze())
        XCTAssertEqual(result.sampleOffset, 5)
    }

    func testStaleAudioAfterTheWriterStops() throws {
        let result = try XCTUnwrap(Run(staleAfterStop: 600).analyze())
        XCTAssertEqual(result.silenceDelay, 600)
        XCTAssertEqual(result.nonZeroAfterStop, 600 - 128)
    }

    func testNothingToAnalyse() {
        let run = Run()
        XCTAssertNil(LoopbackAnalysis.analyze(chirp: run.chirp, writer: [], reader: run.reader, recording: run.recording, bufferFrames: 128))
        XCTAssertNil(LoopbackAnalysis.analyze(chirp: [], writer: run.writer, reader: run.reader, recording: run.recording, bufferFrames: 128))
        let silent = LoopbackAnalysis.analyze(chirp: run.chirp, writer: run.writer, reader: run.reader,
                                              recording: [Float](repeating: 0, count: run.recording.count), bufferFrames: 128)
        XCTAssertNil(silent?.sampleOffset)
        XCTAssertNil(silent?.silenceDelay)
    }

    func testBlockLookup() {
        let blocks = [0, 128, 256].map { IOBlock(sampleTime: 0, nowSampleTime: 0, frames: 128, position: Int64($0)) }
        XCTAssertEqual(LoopbackAnalysis.blockContaining(0, in: blocks)?.position, 0)
        XCTAssertEqual(LoopbackAnalysis.blockContaining(200, in: blocks)?.position, 128)
        XCTAssertEqual(LoopbackAnalysis.blockContaining(383, in: blocks)?.position, 256)
        XCTAssertNil(LoopbackAnalysis.blockContaining(384, in: blocks))
        XCTAssertNil(LoopbackAnalysis.blockContaining(-1, in: blocks))
    }

    // MARK: What "Measure latency" keeps of a take

    func testACleanTakeBecomesAMeasurement() throws {
        let result = try XCTUnwrap(Run().analyze())
        XCTAssertTrue(LoopbackProbe.isGood(result))
        let measurement = try XCTUnwrap(LoopbackMeasurement(result: result, bufferFrameSize: 128, takes: 2))
        XCTAssertEqual(measurement.bufferFrameSize, 128)
        XCTAssertEqual(measurement.meanFrames, 272)
        XCTAssertEqual(measurement.worstFrames, 272)
        XCTAssertEqual(measurement.sampleOffset, 0)
        XCTAssertGreaterThan(measurement.confidence, 0.99)
        XCTAssertEqual(measurement.takes, 2)
    }

    func testAShiftedTakeIsNotGoodButStillMeasured() throws {
        let result = try XCTUnwrap(Run(offset: 5).analyze())
        XCTAssertFalse(LoopbackProbe.isGood(result), "the loopback must be exact in sample time")
        XCTAssertEqual(LoopbackMeasurement(result: result, bufferFrameSize: 128, takes: 1)?.sampleOffset, 5)
    }

    func testASilentTakeIsNoMeasurement() throws {
        let run = Run()
        let silent = try XCTUnwrap(LoopbackAnalysis.analyze(chirp: run.chirp, writer: run.writer, reader: run.reader,
                                                            recording: [Float](repeating: 0, count: run.recording.count),
                                                            bufferFrames: 128))
        XCTAssertFalse(LoopbackProbe.isGood(silent))
        XCTAssertNil(LoopbackMeasurement(result: silent, bufferFrameSize: 128, takes: 1))
    }
}
