@testable import DuettectlCore
import XCTest

final class WAVTests: XCTestCase {
    func testFloat32RoundTripIsExact() throws {
        let left = Sine.make(frequency: 440, dbfs: -12, sampleRate: 48000, seconds: 0.1)
        let right = Sine.make(frequency: 1000, dbfs: -6, sampleRate: 48000, seconds: 0.1)
        let audio = WAVAudio(sampleRate: 48000, channels: 2, samples: Sine.interleave([left, right]))
        let decoded = try WAVAudio.decode(audio.encoded(as: .float32))
        XCTAssertEqual(decoded, audio)
        XCTAssertEqual(decoded.frameCount, 4800)
        XCTAssertEqual(decoded.channel(0), left)
        XCTAssertEqual(decoded.channel(1), right)
        XCTAssertEqual(decoded.channel(2), [])
        XCTAssertEqual(decoded.duration, 0.1, accuracy: 1e-9)
    }

    func testPCM16RoundTripIsWithinOneStep() throws {
        let tone = Sine.make(frequency: 440, dbfs: -1, sampleRate: 44100, seconds: 0.05) + [1.5, -1.5]
        let audio = WAVAudio(sampleRate: 44100, mono: tone)
        let data = audio.encoded(as: .pcm16)
        XCTAssertEqual(data.count, 44 + tone.count * 2)
        let decoded = try WAVAudio.decode(data)
        XCTAssertEqual(decoded.sampleRate, 44100)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.samples.count, tone.count)
        for (a, b) in zip(decoded.samples.dropLast(2), tone.dropLast(2)) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 16000)
        }
        // Out-of-range samples are clipped.
        XCTAssertEqual(decoded.samples[tone.count - 2], 32767.0 / 32768, accuracy: 1e-6)
        XCTAssertEqual(decoded.samples[tone.count - 1], -32767.0 / 32768, accuracy: 1e-6)
    }

    func testDecodes24BitExtensibleFilesAndSkipsOtherChunks() throws {
        var data = Data()
        func bytes(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
        let frames: [Int32] = [0, 4_194_304, -4_194_304, 8_388_607]  // 0, +0.5, -0.5, ~+1
        bytes("RIFF"); u32(0); bytes("WAVE")
        bytes("LIST"); u32(3); bytes("abc"); data.append(0)  // odd-sized chunk with a pad byte
        bytes("fmt "); u32(40)
        u16(0xFFFE); u16(1); u32(48000); u32(48000 * 3); u16(3); u16(24)
        u16(22); u16(24); u32(4)  // cbSize, valid bits, channel mask
        u16(1); data.append(contentsOf: [UInt8](repeating: 0, count: 14))  // KSDATAFORMAT_SUBTYPE_PCM
        bytes("data"); u32(UInt32(frames.count * 3))
        for value in frames {
            let raw = UInt32(bitPattern: value)
            data.append(contentsOf: [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF)])
        }
        let decoded = try WAVAudio.decode(data)
        XCTAssertEqual(decoded.sampleRate, 48000)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.samples.count, 4)
        XCTAssertEqual(decoded.samples[0], 0)
        XCTAssertEqual(decoded.samples[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.samples[2], -0.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.samples[3], 1, accuracy: 1e-6)
    }

    func testRejectsWhatIsNotAWAVFile() {
        XCTAssertThrowsError(try WAVAudio.decode(Data("hello world, not a wav".utf8))) {
            XCTAssertEqual($0 as? WAVError, .notRIFF)
        }
        var noData = WAVAudio(sampleRate: 48000, mono: [0.1, 0.2]).encoded(as: .float32)
        noData.removeSubrange(36..<noData.count)
        XCTAssertThrowsError(try WAVAudio.decode(noData)) { XCTAssertEqual($0 as? WAVError, .missingData) }
        var adpcm = WAVAudio(sampleRate: 48000, mono: [0.1, 0.2]).encoded(as: .pcm16)
        adpcm[20] = 2  // format tag 2: MS ADPCM
        XCTAssertThrowsError(try WAVAudio.decode(adpcm)) {
            XCTAssertEqual($0 as? WAVError, .unsupportedFormat(tag: 2, bits: 16))
        }
    }

    func testWritesAndReadsAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duettectl-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = WAVAudio(sampleRate: 48000, mono: Sine.make(frequency: 1000, dbfs: -12, sampleRate: 48000, seconds: 0.01))
        try audio.write(to: url)
        XCTAssertEqual(try WAVAudio.read(contentsOf: url), audio)
    }

    func testSineHelpers() {
        let tone = Sine.make(frequency: 12000, dbfs: 0, sampleRate: 48000, seconds: 0.0001)  // 4.8 frames -> 5
        XCTAssertEqual(tone.count, 5)
        XCTAssertEqual(tone[0], 0)
        XCTAssertEqual(tone[1], 1, accuracy: 1e-6)
        XCTAssertEqual(Sine.mix([1, 2, 3], [10]), [11, 2, 3])
        XCTAssertEqual(Sine.interleave([[1, 2], [3, 4]]), [1, 3, 2, 4])
        XCTAssertEqual(Sine.interleave([]), [])
    }
}
