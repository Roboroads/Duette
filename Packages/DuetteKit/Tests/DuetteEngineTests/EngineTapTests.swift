import CoreAudio
import DuetteEngine
import DuetteEngineTestSupport
import XCTest

/// M3: the app tap joins the mix. The tap's streams may come before or after the mic's in the
/// aggregate's input buffer list; the layout says where, and the engine follows it.
final class EngineTapTests: XCTestCase {
    private var engine: OpaquePointer!

    override func setUp() {
        super.setUp()
        engine = duette_engine_create()
    }

    override func tearDown() {
        duette_engine_destroy(engine)
        engine = nil
        super.tearDown()
    }

    private func configure(mic: duette_range, tap: duette_range, output: duette_range = range(0, 1),
                           file: StaticString = #filePath, line: UInt = #line) {
        var layout = duette_layout(mic: mic, tap: tap, output: output, sample_rate: 48000)
        XCTAssertEqual(duette_engine_configure(engine, &layout), DUETTE_STATUS_OK, file: file, line: line)
    }

    private func assertOutput(_ output: TestBufferList, left: Float, right: Float,
                              file: StaticString = #filePath, line: UInt = #line) {
        for frame in 0..<output.frames {
            XCTAssertEqual(output.sample(0, channel: 0, frame: frame), left, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(output.sample(0, channel: 1, frame: frame), right, accuracy: 1e-6, file: file, line: line)
        }
    }

    /// A stereo tap with constant left and right.
    private func tapBuffer(_ list: TestBufferList, _ buffer: Int, left: Float, right: Float) {
        list.fill(buffer, channel: 0) { _ in left }
        list.fill(buffer, channel: 1) { _ in right }
    }

    func testTapOnly() {
        configure(mic: range(0, 0), tap: range(0, 1))
        let input = TestBufferList(channels: [2], frames: 64)
        tapBuffer(input, 0, left: 0.3, right: -0.2)
        let output = TestBufferList(channels: [2], frames: 64)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.3, right: -0.2)
    }

    func testTapAfterMic() {
        configure(mic: range(0, 1), tap: range(1, 1))
        let input = TestBufferList(channels: [1, 2], frames: 64)
        input.fill(0, with: 0.25)
        tapBuffer(input, 1, left: 0.1, right: -0.3)
        let output = TestBufferList(channels: [2], frames: 64)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.35, right: -0.05)
    }

    func testTapBeforeMic() {
        configure(mic: range(1, 1), tap: range(0, 1))
        let input = TestBufferList(channels: [2, 1], frames: 64)
        tapBuffer(input, 0, left: 0.1, right: -0.3)
        input.fill(1, with: 0.25)
        let output = TestBufferList(channels: [2], frames: 64)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.35, right: -0.05)
    }

    func testSwappedLayoutsGiveDifferentMixes() {
        // Same buffers, opposite layout: proves the engine reads the layout, not a fixed order.
        let input = TestBufferList(channels: [2, 2], frames: 32)
        tapBuffer(input, 0, left: 0.4, right: 0.0)
        tapBuffer(input, 1, left: 0.2, right: 0.2)
        let output = TestBufferList(channels: [2], frames: 32)

        configure(mic: range(1, 1), tap: range(0, 1))
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.6, right: 0.2)

        configure(mic: range(0, 1), tap: range(1, 1))
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.4, right: 0.4)
    }

    func testMonoTapGoesToBothSides() {
        configure(mic: range(0, 0), tap: range(0, 1))
        let input = TestBufferList(channels: [1], frames: 16, fill: 0.3)
        let output = TestBufferList(channels: [2], frames: 16)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.3, right: 0.3)
    }

    func testNonInterleavedTapSpansTwoBuffers() {
        configure(mic: range(0, 1), tap: range(1, 2))
        let input = TestBufferList(channels: [1, 1, 1], frames: 16)
        input.fill(0, with: 0.1)
        input.fill(1, with: 0.2)
        input.fill(2, with: -0.2)
        let output = TestBufferList(channels: [2], frames: 16)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 0.3, right: -0.1)
    }

    func testTheMixIsHardClipped() {
        configure(mic: range(0, 1), tap: range(1, 1))
        let input = TestBufferList(channels: [1, 2], frames: 16)
        input.fill(0, with: 0.6)
        tapBuffer(input, 1, left: 0.9, right: -0.9)
        let output = TestBufferList(channels: [2], frames: 16)
        runCycle(engine, input: input, output: output)
        assertOutput(output, left: 1.0, right: -0.3)
    }

    func testIOProcWithTapAndMicDoesNotAllocate() {
        configure(mic: range(1, 1), tap: range(0, 1))
        let input = TestBufferList(channels: [2, 1], frames: 256, fill: 0.1)
        let output = TestBufferList(channels: [2, 2], frames: 256)
        runCycle(engine, input: input, output: output)
        duette_alloc_counter_arm()
        for _ in 0..<200 { runCycle(engine, input: input, output: output) }
        XCTAssertEqual(duette_alloc_counter_disarm(), 0)
    }
}
