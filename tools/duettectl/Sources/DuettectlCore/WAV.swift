import Foundation

public enum WAVError: Error, Equatable, CustomStringConvertible {
    case notRIFF
    case notWAVE
    case missingFormat
    case missingData
    case unsupportedFormat(tag: UInt16, bits: UInt16)
    case invalidLayout(String)

    public var description: String {
        switch self {
        case .notRIFF: return "not a RIFF file"
        case .notWAVE: return "not a WAVE file"
        case .missingFormat: return "no 'fmt ' chunk"
        case .missingData: return "no 'data' chunk"
        case .unsupportedFormat(let tag, let bits): return "unsupported sample format \(tag) with \(bits) bits"
        case .invalidLayout(let detail): return "invalid WAV: \(detail)"
        }
    }
}

/// Audio in memory, as read from or written to a WAV file. Samples are interleaved floats, full
/// scale at ±1.
public struct WAVAudio: Equatable {
    public enum Encoding: Equatable {
        /// 32-bit IEEE float (format tag 3).
        case float32
        /// 16-bit signed integer PCM (format tag 1), clipped and rounded.
        case pcm16
    }

    public var sampleRate: Double
    public var channels: Int
    public var samples: [Float]

    public init(sampleRate: Double, channels: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    /// Mono audio from one channel's samples.
    public init(sampleRate: Double, mono: [Float]) {
        self.init(sampleRate: sampleRate, channels: 1, samples: mono)
    }

    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// One channel's samples.
    public func channel(_ index: Int) -> [Float] {
        guard channels > 0, index >= 0, index < channels else { return [] }
        var out = [Float]()
        out.reserveCapacity(frameCount)
        var at = index
        while at < samples.count {
            out.append(samples[at])
            at += channels
        }
        return out
    }

    // MARK: Encoding

    public func encoded(as encoding: Encoding = .float32) -> Data {
        let bits: UInt16 = encoding == .float32 ? 32 : 16
        let tag: UInt16 = encoding == .float32 ? 3 : 1
        let bytesPerSample = Int(bits) / 8
        let blockAlign = UInt16(channels * bytesPerSample)
        let dataSize = UInt32(samples.count * bytesPerSample)
        let rate = UInt32(sampleRate.rounded())

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: Array("RIFF".utf8))
        Self.append(UInt32(36) + dataSize, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        Self.append(UInt32(16), to: &data)
        Self.append(tag, to: &data)
        Self.append(UInt16(channels), to: &data)
        Self.append(rate, to: &data)
        Self.append(rate * UInt32(blockAlign), to: &data)
        Self.append(blockAlign, to: &data)
        Self.append(bits, to: &data)
        data.append(contentsOf: Array("data".utf8))
        Self.append(dataSize, to: &data)
        switch encoding {
        case .float32:
            for sample in samples { Self.append(sample.bitPattern, to: &data) }
        case .pcm16:
            for sample in samples {
                let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
                let value = Int16((clipped * 32767).rounded())
                Self.append(UInt16(bitPattern: value), to: &data)
            }
        }
        return data
    }

    public func write(to url: URL, as encoding: Encoding = .float32) throws {
        try encoded(as: encoding).write(to: url)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    // MARK: Decoding

    public static func read(contentsOf url: URL) throws -> WAVAudio {
        try decode(Data(contentsOf: url))
    }

    /// Reads PCM (8, 16, 24 or 32 bit), 32-bit float and WAVE_FORMAT_EXTENSIBLE files.
    public static func decode(_ data: Data) throws -> WAVAudio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF" else { throw WAVError.notRIFF }
        guard String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw WAVError.notWAVE }

        var format: (tag: UInt16, channels: Int, rate: Double, bits: UInt16)?
        var payload: Range<Int>?
        var at = 12
        while at + 8 <= bytes.count {
            let id = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            let declared = Int(readUInt32(bytes, at + 4))
            let start = at + 8
            let end = min(bytes.count, start + declared)
            if id == "fmt " {
                guard end - start >= 16 else { throw WAVError.invalidLayout("'fmt ' chunk is \(end - start) bytes") }
                var tag = readUInt16(bytes, start)
                let channels = Int(readUInt16(bytes, start + 2))
                let rate = Double(readUInt32(bytes, start + 4))
                let bits = readUInt16(bytes, start + 14)
                if tag == 0xFFFE {
                    // WAVE_FORMAT_EXTENSIBLE: the real tag is the first two bytes of the sub-format GUID.
                    guard end - start >= 26 else { throw WAVError.invalidLayout("short extensible 'fmt ' chunk") }
                    tag = readUInt16(bytes, start + 24)
                }
                format = (tag, channels, rate, bits)
            } else if id == "data" {
                payload = start..<end
            }
            // Chunks are padded to an even size.
            at = start + declared + (declared & 1)
        }
        guard let format else { throw WAVError.missingFormat }
        guard let payload else { throw WAVError.missingData }
        guard format.channels > 0 else { throw WAVError.invalidLayout("\(format.channels) channels") }
        guard format.rate > 0 else { throw WAVError.invalidLayout("sample rate \(format.rate)") }

        let samples: [Float]
        switch (format.tag, format.bits) {
        case (3, 32):
            samples = stride(from: payload.lowerBound, to: payload.upperBound - 3, by: 4).map {
                Float(bitPattern: readUInt32(bytes, $0))
            }
        case (1, 8):
            samples = bytes[payload].map { (Float($0) - 128) / 128 }
        case (1, 16):
            samples = stride(from: payload.lowerBound, to: payload.upperBound - 1, by: 2).map {
                Float(Int16(bitPattern: readUInt16(bytes, $0))) / 32768
            }
        case (1, 24):
            samples = stride(from: payload.lowerBound, to: payload.upperBound - 2, by: 3).map { i in
                let raw = Int32(bytes[i]) | (Int32(bytes[i + 1]) << 8) | (Int32(bytes[i + 2]) << 16)
                let signed = (raw << 8) >> 8
                return Float(signed) / 8_388_608
            }
        case (1, 32):
            samples = stride(from: payload.lowerBound, to: payload.upperBound - 3, by: 4).map {
                Float(Int32(bitPattern: readUInt32(bytes, $0))) / 2_147_483_648
            }
        default:
            throw WAVError.unsupportedFormat(tag: format.tag, bits: format.bits)
        }
        // Drop a partial last frame.
        let whole = samples.count - samples.count % format.channels
        return WAVAudio(sampleRate: format.rate, channels: format.channels, samples: Array(samples.prefix(whole)))
    }

    static func readUInt16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
}

/// Sine waves for tests and tone files.
public enum Sine {
    /// `seconds` of a sine at `frequency` with peak level `dbfs`, starting at phase 0.
    public static func make(frequency: Double, dbfs: Double, sampleRate: Double, seconds: Double,
                            phase: Double = 0) -> [Float] {
        let amplitude = pow(10, dbfs / 20)
        let frames = Int((seconds * sampleRate).rounded())
        return (0..<frames).map { i in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / sampleRate + phase))
        }
    }

    /// The sample-by-sample sum of signals, as long as the longest.
    public static func mix(_ signals: [Float]...) -> [Float] {
        let length = signals.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: length)
        for signal in signals {
            for (i, sample) in signal.enumerated() { out[i] += sample }
        }
        return out
    }

    /// Interleaves channels of equal length.
    public static func interleave(_ channels: [[Float]]) -> [Float] {
        guard let length = channels.map(\.count).min(), !channels.isEmpty else { return [] }
        var out = [Float]()
        out.reserveCapacity(length * channels.count)
        for i in 0..<length {
            for channel in channels { out.append(channel[i]) }
        }
        return out
    }
}
