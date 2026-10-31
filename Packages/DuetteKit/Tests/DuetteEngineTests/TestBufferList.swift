import CoreAudio
import DuetteEngine

/// A synthetic AudioBufferList for feeding the IOProc: one buffer per entry of `channels`, each
/// holding `frames` interleaved frames of Float32.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(channels: [Int], frames: Int, fill: Float = 0) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(channels.count, 1))
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels.count)
        for (index, count) in channels.enumerated() {
            let samples = max(count * frames, 1)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            data.initialize(repeating: fill, count: samples)
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

    var bufferCount: Int { storage.count }

    func channels(of buffer: Int) -> Int { Int(list[buffer].mNumberChannels) }

    func sample(_ buffer: Int, channel: Int, frame: Int) -> Float {
        storage[buffer][frame * channels(of: buffer) + channel]
    }

    func set(_ buffer: Int, channel: Int, frame: Int, to value: Float) {
        storage[buffer][frame * channels(of: buffer) + channel] = value
    }

    /// Fills one channel of one buffer with `value(frame)`.
    func fill(_ buffer: Int, channel: Int, _ value: (Int) -> Float) {
        for frame in 0..<frames { set(buffer, channel: channel, frame: frame, to: value(frame)) }
    }

    /// Fills every channel of one buffer with a constant.
    func fill(_ buffer: Int, with value: Float) {
        for channel in 0..<channels(of: buffer) { fill(buffer, channel: channel) { _ in value } }
    }

    /// Every sample of one buffer, interleaved.
    func samples(_ buffer: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[buffer], count: channels(of: buffer) * frames))
    }

    /// Makes buffer `index` claim `frames` frames, without touching its data.
    func setFrames(_ buffer: Int, _ frames: Int) {
        var entry = list[buffer]
        entry.mDataByteSize = UInt32(Int(entry.mNumberChannels) * frames * MemoryLayout<Float>.size)
        list[buffer] = entry
    }

    /// Detaches the data of buffer `index`, as the HAL does for a stream that is switched off.
    func dropData(_ buffer: Int) {
        var entry = list[buffer]
        entry.mData = nil
        list[buffer] = entry
    }
}

/// Runs one IOProc cycle of `engine`.
@discardableResult
func runCycle(_ engine: OpaquePointer, input: TestBufferList, output: TestBufferList,
              hostTime: UInt64 = 0) -> OSStatus {
    var now = AudioTimeStamp()
    var inputTime = AudioTimeStamp()
    var outputTime = AudioTimeStamp()
    outputTime.mHostTime = hostTime
    outputTime.mFlags = hostTime != 0 ? .hostTimeValid : []
    return duette_engine_ioproc(0, &now, input.list.unsafePointer, &inputTime,
                                output.list.unsafeMutablePointer, &outputTime, UnsafeMutableRawPointer(engine))
}

func range(_ first: Int, _ count: Int) -> duette_range {
    duette_range(first: UInt32(first), count: UInt32(count))
}
