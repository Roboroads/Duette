import CoreAudio
@testable import DuetteAudio
import XCTest

final class StreamLayoutTests: XCTestCase {
    private let sinkID: AudioObjectID = 50
    private let micID: AudioObjectID = 60

    private func sink(outputs: [StreamInfo] = [StreamInfo(id: 51, channels: 2)]) -> LayoutMember {
        LayoutMember(role: .sink, objectID: sinkID, streams: outputs)
    }

    private func mic(_ streams: [StreamInfo]) -> LayoutMember {
        LayoutMember(role: .mic, objectID: micID, streams: streams)
    }

    func testMicStreamsFoundByTheirObjectIDs() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 61, channels: 1)],
            members: [sink(outputs: []), mic([StreamInfo(id: 61, channels: 1)])])
        XCTAssertEqual(layout.method, .streamIDs)
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 0, count: 1))
    }

    func testOwnersIdentifyStreamsWhenTheAggregateHasItsOwnStreamObjects() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2, owner: sinkID), StreamInfo(id: 901, channels: 2, owner: micID)],
            members: [sink(), mic([StreamInfo(id: 61, channels: 2)])])
        XCTAssertEqual(layout.method, .owners)
        XCTAssertEqual(layout.range(.sink), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 1, count: 1))
    }

    func testChannelCountsTellTheOrderApart() throws {
        // Output scope of an aggregate with a headset mic: sink 2 ch, then the headset's 1 ch output.
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 1, owner: 1), StreamInfo(id: 901, channels: 2, owner: 1)],
            members: [sink(), mic([StreamInfo(id: 62, channels: 1)])])
        XCTAssertEqual(layout.method, .channelCounts)
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.sink), BufferRange(first: 1, count: 1))
    }

    func testIdenticalMembersFallBackToCompositionOrder() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2, owner: 1), StreamInfo(id: 901, channels: 2, owner: 1)],
            members: [sink(), mic([StreamInfo(id: 61, channels: 2)])])
        XCTAssertEqual(layout.method, .memberOrder)
        XCTAssertEqual(layout.range(.sink), BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 1, count: 1))
    }

    func testNonInterleavedStreamsTakeOneBufferPerChannel() throws {
        let layout = try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 51, channels: 2, buffers: 2), StreamInfo(id: 61, channels: 2)],
            members: [sink(outputs: [StreamInfo(id: 51, channels: 2, buffers: 2)]), mic([StreamInfo(id: 61, channels: 2)])])
        XCTAssertEqual(layout.range(.sink), BufferRange(first: 0, count: 2))
        XCTAssertEqual(layout.range(.mic), BufferRange(first: 2, count: 1))
    }

    func testAMissingStreamIsAnError() {
        XCTAssertThrowsError(try StreamLayoutResolver.resolve(
            streams: [StreamInfo(id: 900, channels: 2)],
            members: [sink(), mic([StreamInfo(id: 61, channels: 2)])])) { error in
            XCTAssertEqual(error as? StreamLayoutError, .streamCountMismatch(expected: 2, actual: 1))
        }
    }

    func testAMemberWithoutStreamsGetsNoRange() throws {
        let layout = try StreamLayoutResolver.resolve(streams: [], members: [sink(outputs: [])])
        XCTAssertEqual(layout.range(.sink), .none)
        XCTAssertEqual(layout.range(.mic), .none)
    }

    func testEngineLayoutTakesTheMicFromInputAndTheSinkFromOutput() throws {
        let input = StreamLayout(ranges: [.mic: BufferRange(first: 0, count: 1)], method: .streamIDs)
        let output = StreamLayout(ranges: [.sink: BufferRange(first: 0, count: 1), .mic: BufferRange(first: 1, count: 1)],
                                  method: .channelCounts)
        let layout = EngineLayout(input: input, output: output, sampleRate: 48000)
        XCTAssertEqual(layout.mic, BufferRange(first: 0, count: 1))
        XCTAssertEqual(layout.output, BufferRange(first: 0, count: 1))
    }
}

final class MixEngineTests: XCTestCase {
    func testConfigureRefusesALayoutWithoutOutput() {
        let engine = MixEngine()
        XCTAssertThrowsError(try engine.configure(EngineLayout(output: .none, sampleRate: 48000))) { error in
            XCTAssertEqual(error as? MixEngineError, .invalidLayout)
        }
        XCTAssertNoThrow(try engine.configure(EngineLayout(output: BufferRange(first: 0, count: 1), sampleRate: 48000)))
        XCTAssertFalse(engine.isRunning)
    }

    func testGainsMutesToneAndCountersRoundTrip() {
        let engine = MixEngine()
        engine.setGain(1.5, for: .mic)
        XCTAssertEqual(engine.gain(for: .mic), 1.5)
        engine.setGain(9, for: .app)
        XCTAssertEqual(engine.gain(for: .app), MixEngine.maxGain)
        XCTAssertEqual(engine.gain(for: .output), 1)
        engine.setMuted(true, for: .output)
        XCTAssertTrue(engine.isMuted(.output))
        XCTAssertFalse(engine.isMuted(.mic))
        XCTAssertFalse(engine.testTone)
        engine.testTone = true
        XCTAssertTrue(engine.testTone)
        XCTAssertEqual(engine.meters(), Meters())
        XCTAssertEqual(engine.stats(), EngineStats())
        engine.countOverload()
        XCTAssertEqual(engine.stats().overloads, 1)
    }

    func testStartOnAMissingDeviceThrowsTheHALError() throws {
        let engine = MixEngine()
        try engine.configure(EngineLayout(output: BufferRange(first: 0, count: 1), sampleRate: 48000))
        XCTAssertThrowsError(try engine.start(on: 0xFFFF_FF00)) { error in
            XCTAssertNotEqual((error as? CoreAudioError)?.status, 0)
        }
        XCTAssertFalse(engine.isRunning)
    }
}
