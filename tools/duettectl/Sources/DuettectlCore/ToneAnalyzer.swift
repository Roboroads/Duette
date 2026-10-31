import Foundation

/// A sine found in a signal.
public struct ToneMeasurement: Equatable, CustomStringConvertible {
    /// Hz, interpolated between FFT bins.
    public var frequency: Double
    /// Peak amplitude, linear (1.0 is full scale).
    public var amplitude: Double

    public init(frequency: Double, amplitude: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    /// Peak level in dB relative to full scale: a sine with peak 1.0 is 0 dBFS.
    public var dbfs: Double { ToneMeasurement.dbfs(amplitude) }

    public static func dbfs(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-12))
    }

    public var description: String {
        String(format: "%.2f Hz at %.2f dBFS", frequency, dbfs)
    }
}

/// Power spectrum of a Hann-windowed block, for measuring tones.
///
/// The level of a tone is the energy of its main lobe (the peak bin and four on each side), so it
/// does not depend on where the tone falls between two bins. Its frequency is the peak bin
/// interpolated with a parabola through the log magnitudes of the peak and its neighbours.
public struct Spectrum {
    public let sampleRate: Double
    /// FFT length.
    public let size: Int
    /// |X[k]|² for k in 0...size/2.
    public let power: [Double]
    /// Sum of the squared window: turns lobe energy back into an amplitude.
    let windowEnergy: Double

    /// Bins on each side of a peak that count as its lobe.
    public static let lobeBins = 4

    /// Uses the largest power of two of samples that fits (at most `maxSize`), centred in
    /// `samples`. Nil when there are fewer than 1024 samples.
    public init?(samples: [Float], sampleRate: Double, maxSize: Int = 65536) {
        guard sampleRate > 0, samples.count >= 1024 else { return nil }
        var n = 1024
        while n * 2 <= min(samples.count, maxSize) { n *= 2 }
        let offset = (samples.count - n) / 2

        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        var energy = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            let x = Double(samples[offset + i])
            re[i] = (x.isFinite ? x : 0) * w
            energy += w * w
        }
        FFT.transform(&re, &im)
        var power = [Double](repeating: 0, count: n / 2 + 1)
        for k in 0...(n / 2) { power[k] = re[k] * re[k] + im[k] * im[k] }

        self.sampleRate = sampleRate
        self.size = n
        self.power = power
        self.windowEnergy = energy
    }

    public var binHz: Double { sampleRate / Double(size) }

    /// The amplitude of a sine whose positive-frequency lobe holds `energy`.
    func amplitude(ofLobeEnergy energy: Double) -> Double {
        // Parseval: sum |x w|² = (1/N) sum |X|². A sine of peak A puts (A²/4) sum w² of that in
        // each of its two lobes.
        (4 * energy / (Double(size) * windowEnergy)).squareRoot()
    }

    func lobeEnergy(at peak: Int) -> Double {
        let low = max(1, peak - Self.lobeBins)
        let high = min(power.count - 2, peak + Self.lobeBins)
        guard low <= high else { return 0 }
        return power[low...high].reduce(0, +)
    }

    func interpolatedFrequency(at peak: Int) -> Double {
        guard peak > 0, peak < power.count - 1 else { return Double(peak) * binHz }
        let a = power[peak - 1], b = power[peak], c = power[peak + 1]
        guard a > 0, b > 0, c > 0 else { return Double(peak) * binHz }
        // ln|X| = ln(power) / 2; the factor cancels.
        let la = log(a), lb = log(b), lc = log(c)
        let denominator = la - 2 * lb + lc
        let delta = denominator == 0 ? 0 : 0.5 * (la - lc) / denominator
        return (Double(peak) + max(-0.5, min(0.5, delta))) * binHz
    }

    func measurement(at peak: Int) -> ToneMeasurement {
        ToneMeasurement(frequency: interpolatedFrequency(at: peak), amplitude: amplitude(ofLobeEnergy: lobeEnergy(at: peak)))
    }

    /// The strongest tone within `searchHz` of `frequency`, or nil if that range holds only
    /// silence.
    public func tone(near frequency: Double, searchHz: Double = 25) -> ToneMeasurement? {
        let low = max(1, Int(((frequency - searchHz) / binHz).rounded(.down)))
        let high = min(power.count - 2, Int(((frequency + searchHz) / binHz).rounded(.up)))
        guard low <= high else { return nil }
        var peak = low
        for k in low...high where power[k] > power[peak] { peak = k }
        guard power[peak] > 0 else { return nil }
        return measurement(at: peak)
    }

    /// The strongest tones at or above `minimumDBFS`, strongest first. Local maxima within a
    /// lobe of a stronger tone (its side lobes) are left out.
    public func peaks(minimumDBFS: Double = -60, limit: Int = 8) -> [ToneMeasurement] {
        var candidates: [(bin: Int, power: Double)] = []
        if power.count >= 3 {
            for k in 1..<(power.count - 1) where power[k] > power[k - 1] && power[k] >= power[k + 1] {
                candidates.append((k, power[k]))
            }
        }
        candidates.sort { $0.power > $1.power }
        var accepted: [Int] = []
        var result: [ToneMeasurement] = []
        for candidate in candidates {
            if result.count >= limit { break }
            if accepted.contains(where: { abs($0 - candidate.bin) <= 2 * Self.lobeBins }) { continue }
            let tone = measurement(at: candidate.bin)
            guard tone.dbfs >= minimumDBFS else { break }
            accepted.append(candidate.bin)
            result.append(tone)
        }
        return result
    }

    /// Everything outside the lobes of `tones` (and DC), as the level of a sine with the same
    /// energy. Noise, clicks and resampling artefacts all land here.
    public func residualDBFS(excluding tones: [ToneMeasurement]) -> Double {
        var excluded = Set<Int>()
        for tone in tones {
            let bin = Int((tone.frequency / binHz).rounded())
            for k in (bin - 2 * Self.lobeBins)...(bin + 2 * Self.lobeBins) { excluded.insert(k) }
        }
        var energy = 0.0
        if power.count >= 3 {
            for k in 1..<(power.count - 1) where !excluded.contains(k) { energy += power[k] }
        }
        return ToneMeasurement.dbfs(amplitude(ofLobeEnergy: energy))
    }
}

/// In-place iterative radix-2 FFT.
public enum FFT {
    /// Transforms `re` + i·`im` in place. Their length must be a power of two.
    public static func transform(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        precondition(n == im.count && n > 0 && n & (n - 1) == 0, "FFT length must be a power of two")
        // Bit-reversal permutation.
        var j = 0
        for i in 1..<max(n, 2) where i < n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let stepRe = cos(angle), stepIm = sin(angle)
            var start = 0
            while start < n {
                var wRe = 1.0, wIm = 0.0
                for k in 0..<(length / 2) {
                    let a = start + k
                    let b = a + length / 2
                    let tRe = re[b] * wRe - im[b] * wIm
                    let tIm = re[b] * wIm + im[b] * wRe
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] += tRe
                    im[a] += tIm
                    let nextRe = wRe * stepRe - wIm * stepIm
                    wIm = wRe * stepIm + wIm * stepRe
                    wRe = nextRe
                }
                start += length
            }
            length *= 2
        }
    }
}

/// What a check expects of one frequency.
public enum ToneLevel: Equatable {
    /// Present (above -60 dBFS) at any level.
    case present
    /// At this level, within the tolerance.
    case dbfs(Double)
    /// Absent: nothing at that frequency reaches this level.
    case below(Double)
}

public struct ToneExpectation: Equatable, CustomStringConvertible {
    public var frequency: Double
    public var level: ToneLevel
    public var toleranceHz: Double
    public var toleranceDB: Double

    /// The plan's thresholds: ±2 Hz and ±1 dB.
    public static let defaultToleranceHz = 2.0
    public static let defaultToleranceDB = 1.0
    /// "Present" means at least this loud.
    public static let presenceDBFS = -60.0

    public init(frequency: Double, level: ToneLevel = .present, toleranceHz: Double = defaultToleranceHz,
                toleranceDB: Double = defaultToleranceDB) {
        self.frequency = frequency
        self.level = level
        self.toleranceHz = toleranceHz
        self.toleranceDB = toleranceDB
    }

    public static func at(_ frequency: Double, _ dbfs: Double) -> ToneExpectation {
        ToneExpectation(frequency: frequency, level: .dbfs(dbfs))
    }

    public static func absent(_ frequency: Double, below dbfs: Double = -60) -> ToneExpectation {
        ToneExpectation(frequency: frequency, level: .below(dbfs))
    }

    public var description: String {
        switch level {
        case .present: return String(format: "%.0f Hz present", frequency)
        case .dbfs(let level): return String(format: "%.0f Hz at %.1f dBFS", frequency, level)
        case .below(let level): return String(format: "%.0f Hz below %.0f dBFS", frequency, level)
        }
    }

    /// Parses "440@-12" (level), "440" (present) or "1000<-60" (absent), comma separated.
    public static func parseList(_ text: String) throws -> [ToneExpectation] {
        try text.split(separator: ",").map { item -> ToneExpectation in
            let part = item.trimmingCharacters(in: .whitespaces)
            if let at = part.firstIndex(of: "@") {
                guard let frequency = Double(part[..<at]), let level = Double(part[part.index(after: at)...]),
                      frequency > 0 else { throw ArgumentError.invalidValue(option: "expect", value: part, expected: "FREQ@DBFS") }
                return .at(frequency, level)
            }
            if let lt = part.firstIndex(of: "<") {
                guard let frequency = Double(part[..<lt]), let level = Double(part[part.index(after: lt)...]),
                      frequency > 0 else { throw ArgumentError.invalidValue(option: "expect", value: part, expected: "FREQ<DBFS") }
                return .absent(frequency, below: level)
            }
            guard let frequency = Double(part), frequency > 0 else {
                throw ArgumentError.invalidValue(option: "expect", value: part, expected: "a frequency")
            }
            return ToneExpectation(frequency: frequency)
        }
    }
}

public struct ToneCheckResult: Equatable, CustomStringConvertible {
    public var expectation: ToneExpectation
    public var measured: ToneMeasurement?
    public var passed: Bool

    public var description: String {
        let found = measured.map { $0.description } ?? "nothing"
        return "\(passed ? "ok" : "FAILED"): want \(expectation), found \(found)"
    }
}

/// Checks a recording for the tones a test expects.
public enum ToneChecker {
    public static func check(_ samples: [Float], sampleRate: Double, expect: [ToneExpectation]) -> [ToneCheckResult] {
        guard let spectrum = Spectrum(samples: samples, sampleRate: sampleRate) else {
            return expect.map { ToneCheckResult(expectation: $0, measured: nil, passed: $0.level.isAbsence) }
        }
        return check(spectrum, expect: expect)
    }

    public static func check(_ spectrum: Spectrum, expect: [ToneExpectation]) -> [ToneCheckResult] {
        expect.map { expectation in
            let search = max(expectation.toleranceHz * 4, 10)
            let tone = spectrum.tone(near: expectation.frequency, searchHz: search)
            let passed: Bool
            switch expectation.level {
            case .present:
                passed = tone.map { abs($0.frequency - expectation.frequency) <= expectation.toleranceHz
                    && $0.dbfs >= ToneExpectation.presenceDBFS } ?? false
            case .dbfs(let level):
                passed = tone.map { abs($0.frequency - expectation.frequency) <= expectation.toleranceHz
                    && abs($0.dbfs - level) <= expectation.toleranceDB } ?? false
            case .below(let level):
                passed = tone.map { $0.dbfs < level } ?? true
            }
            return ToneCheckResult(expectation: expectation, measured: tone, passed: passed)
        }
    }
}

extension ToneLevel {
    var isAbsence: Bool {
        if case .below = self { return true }
        return false
    }
}

/// Level statistics of a block of samples.
public struct SignalStats: Equatable {
    public var peak: Float
    public var rms: Double
    /// Frames that are exactly 0.
    public var zeros: Int
    /// The longest run of exact zeros.
    public var longestZeroRun: Int
    public var count: Int

    public init(_ samples: [Float]) {
        var peak: Float = 0
        var sum = 0.0
        var zeros = 0, run = 0, longest = 0
        for x in samples {
            peak = max(peak, abs(x))
            sum += Double(x) * Double(x)
            if x == 0 {
                zeros += 1
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        self.peak = peak
        self.rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()
        self.zeros = zeros
        self.longestZeroRun = longest
        self.count = samples.count
    }

    public var peakDBFS: Double { ToneMeasurement.dbfs(Double(peak)) }
}
