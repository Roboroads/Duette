import CoreAudio
import DuetteEngine
import DuetteEngineTestSupport
import XCTest

/// M2: the IOProc takes the mic from the aggregate's input buffer list and writes it, mono, to
/// both channels of the sink's buffers.
final class EngineMicTests: XCTestCase {
    private var engine: OpaquePointer!

    override func setUp() {
        super.setUp()
        engine = duette_engine_create()
        XCTAssertNotNil(engine)
    }

    override func tearDown() {
        duette_engine_destroy(engine)
        engine = nil
        super.tearDown()
    }

    private func configure(mic: duette_range, output: duette_range, rate: Double = 48000,
                           file: StaticString = #filePath, line: UInt = #line) {
        var layout = duette_layout(mic: mic, output: output, sample_rate: rate)
        XCTAssertEqual(duette_engine_configure(engine, &layout), DUETTE_STATUS_OK, file: file, line: line)
    }

    func testUnconfiguredEngineWritesSilence() {
        let input = TestBufferList(channels: [2], frames: 64, fill: 0.5)
        let output = TestBufferList(channels: [2], frames: 64, fill: 0.7)
        XCTAssertEqual(runCycle(engine, input: input, output: output), 0)
        XCTAssertEqual(output.samples(0), [Float](repeating: 0, count: 128))
    }

    func testStereoMicIsAveragedToMonoOnBothSides() {
        configure(mic: range(0, 1), output: range(0, 1))
        let input = TestBufferList(channels: [2], frames: 128)
        input.fill(0, channel: 0) { _ in 0.2 }
        input.fill(0, channel: 1) { _ in 0.6 }
        let output = TestBufferList(channels: [2], frames: 128, fill: 9)
        runCycle(engine, input: input, output: output)
        for frame in 0..<128 {
            XCTAssertEqual(output.sample(0, channel: 0, frame: frame), 0.4, accuracy: 1e-6)
            XCTAssertEqual(output.sample(0, channel: 1, frame: frame), 0.4, accuracy: 1e-6)
        }
    }

    func testMonoMicAfterAnotherStreamFollowsTheLayout() {
        // Buffer 0 is someone else's stream; the mic is buffer 1.
        configure(mic: range(1, 1), output: range(0, 1))
        let input = TestBufferList(channels: [2, 1], frames: 32)
        input.fill(0, with: 1.0)
        input.fill(1, channel: 0) { frame in Float(frame) / 100 }
        let output = TestBufferList(channels: [2], frames: 32)
        runCycle(engine, input: input, output: output)
        for frame in 0..<32 {
            XCTAssertEqual(output.sample(0, channel: 0, frame: frame), Float(frame) / 100, accuracy: 1e-6)
            XCTAssertEqual(output.sample(0, channel: 1, frame: frame), Float(frame) / 100, accuracy: 1e-6)
        }
    }

    func testMicSplitOverMonoBuffersAndPlanarSink() {
        configure(mic: range(0, 2), output: range(0, 2))
        let input = TestBufferList(channels: [1, 1], frames: 16)
        input.fill(0, with: 0.1)
        input.fill(1, with: 0.3)
        let output = TestBufferList(channels: [1, 1], frames: 16)
        runCycle(engine, input: input, output: output)
        for frame in 0..<16 {
            XCTAssertEqual(output.sample(0, channel: 0, frame: frame), 0.2, accuracy: 1e-6)
            XCTAssertEqual(output.sample(1, channel: 0, frame: frame), 0.2, accuracy: 1e-6)
        }
    }

    func testOutputBuffersOutsideTheSinkAreSilenced() {
        // The mic device's own output stream follows the sink's in the aggregate.
        configure(mic: range(0, 1), output: range(0, 1))
        let input = TestBufferList(channels: [1], frames: 8, fill: 0.5)
        let output = TestBufferList(channels: [2, 2], frames: 8, fill: 0.9)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(output.samples(0), [Float](repeating: 0.5, count: 16))
        XCTAssertEqual(output.samples(1), [Float](repeating: 0, count: 16))
    }

    func testNoMicGivesSilence() {
        configure(mic: range(0, 0), output: range(0, 1))
        let input = TestBufferList(channels: [], frames: 8)
        let output = TestBufferList(channels: [2], frames: 8, fill: 0.9)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(output.samples(0), [Float](repeating: 0, count: 16))
    }

    func testStaleLayoutBeyondTheBufferListGivesSilence() {
        configure(mic: range(3, 2), output: range(0, 1))
        let input = TestBufferList(channels: [1], frames: 8, fill: 0.5)
        let output = TestBufferList(channels: [2], frames: 8, fill: 0.9)
        XCTAssertEqual(runCycle(engine, input: input, output: output), 0)
        XCTAssertEqual(output.samples(0), [Float](repeating: 0, count: 16))
    }

    func testShortInputLeavesTheRestSilent() {
        configure(mic: range(0, 1), output: range(0, 1))
        let input = TestBufferList(channels: [1], frames: 8, fill: 0.5)
        input.setFrames(0, 4)
        let output = TestBufferList(channels: [2], frames: 8, fill: 0.9)
        runCycle(engine, input: input, output: output)
        let samples = output.samples(0)
        XCTAssertEqual(Array(samples[0..<8]), [Float](repeating: 0.5, count: 8))
        XCTAssertEqual(Array(samples[8..<16]), [Float](repeating: 0, count: 8))
    }

    func testMicBufferWithoutDataCountsAsSilence() {
        configure(mic: range(0, 1), output: range(0, 1))
        let input = TestBufferList(channels: [1], frames: 8, fill: 0.5)
        input.dropData(0)
        let output = TestBufferList(channels: [2], frames: 8, fill: 0.9)
        runCycle(engine, input: input, output: output)
        XCTAssertEqual(output.samples(0), [Float](repeating: 0, count: 16))
    }

    func testConfigureRejectsBadLayouts() {
        var noOutput = duette_layout(mic: range(0, 1), output: range(0, 0), sample_rate: 48000)
        XCTAssertEqual(duette_engine_configure(engine, &noOutput), DUETTE_STATUS_INVALID_ARGUMENT)
        var noRate = duette_layout(mic: range(0, 1), output: range(0, 1), sample_rate: 0)
        XCTAssertEqual(duette_engine_configure(engine, &noRate), DUETTE_STATUS_INVALID_ARGUMENT)
        var nanRate = duette_layout(mic: range(0, 1), output: range(0, 1), sample_rate: .nan)
        XCTAssertEqual(duette_engine_configure(engine, &nanRate), DUETTE_STATUS_INVALID_ARGUMENT)
    }

    func testStartNeedsAConfiguredEngineAndARealDevice() {
        var procID: AudioDeviceIOProcID?
        XCTAssertNotEqual(duette_engine_start(engine, 0, &procID), 0)
        XCTAssertNil(procID)
        configure(mic: range(0, 1), output: range(0, 1))
        // No such device: the HAL refuses the IOProc and the engine stays stopped.
        XCTAssertNotEqual(duette_engine_start(engine, 0xFFFF_FF00, &procID), 0)
        XCTAssertNil(procID)
        XCTAssertFalse(duette_engine_is_running(engine))
    }

    func testAllocationCounterSeesAllocations() {
        duette_alloc_counter_arm()
        duette_alloc_counter_probe()
        XCTAssertEqual(duette_alloc_counter_disarm(), 1)
    }

    func testIOProcDoesNotAllocate() {
        configure(mic: range(1, 1), output: range(0, 2))
        let input = TestBufferList(channels: [2, 2], frames: 512, fill: 0.25)
        let output = TestBufferList(channels: [1, 1], frames: 512)
        runCycle(engine, input: input, output: output)  // warm up
        duette_alloc_counter_arm()
        for _ in 0..<200 { runCycle(engine, input: input, output: output) }
        XCTAssertEqual(duette_alloc_counter_disarm(), 0)
    }
}
