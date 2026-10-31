@testable import DuettectlCore
import XCTest

/// The FFT tone checker against synthetic signals and synthetic WAV data.
final class ToneAnalyzerTests: XCTestCase {
    func testFFTOfAKnownSignal() {
        // x[n] = cos(2 pi 3 n / 16): energy only in bins 3 and 13, each N/2.
        var re = (0..<16).map { cos(2 * Double.pi * 3 * Double($0) / 16) }
        var im = [Double](repeating: 0, count: 16)
        FFT.transform(&re, &im)
        for k in 0..<16 {
            let magnitude = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            XCTAssertEqual(magnitude, k == 3 || k == 13 ? 8 : 0, accuracy: 1e-9, "bin \(k)")
        }
        // An impulse has a flat spectrum.
        var impulseRe = [Double](repeating: 0, count: 8)
        var impulseIm = [Double](repeating: 0, count: 8)
        impulseRe[0] = 1
        FFT.transform(&impulseRe, &impulseIm)
        for k in 0..<8 { XCTAssertEqual(impulseRe[k], 1, accuracy: 1e-12) }
    }

    func testMeasuresASineToATenthOfAHertzAndATenthOfADecibel() throws {
        for (frequency, dbfs) in [(440.0, -12.0), (1000.2, -12.0), (441.37, -6.0), (997.0, -30.0)] {
            let tone = Sine.make(frequency: frequency, dbfs: dbfs, sampleRate: 48000, seconds: 1.5, phase: 0.3)
            let spectrum = try XCTUnwrap(Spectrum(samples: tone, sampleRate: 48000))
            XCTAssertEqual(spectrum.size, 65536)
            let measured = try XCTUnwrap(spectrum.tone(near: frequency))
            XCTAssertEqual(measured.frequency, frequency, accuracy: 0.1, "\(frequency) Hz")
            XCTAssertEqual(measured.dbfs, dbfs, accuracy: 0.1, "\(frequency) Hz")
        }
    }

    func testWorksAt44100AndOnShortBlocks() throws {
        let tone = Sine.make(frequency: 440, dbfs: -12, sampleRate: 44100, seconds: 0.5)
        let spectrum = try XCTUnwrap(Spectrum(samples: tone, sampleRate: 44100))
        XCTAssertEqual(spectrum.size, 16384)
        let measured = try XCTUnwrap(spectrum.tone(near: 440))
        XCTAssertEqual(measured.frequency, 440, accuracy: 0.2)
        XCTAssertEqual(measured.dbfs, -12, accuracy: 0.1)
        XCTAssertNil(Spectrum(samples: [Float](repeating: 0.1, count: 1000), sampleRate: 48000))
    }

    func testTwoTonesInASyntheticWAVPassTheMixCheck() throws {
        // What verify-mix expects in "Duette": the app's 440 Hz and the test mic's 1 kHz, both
        // at -12 dBFS, on both channels, as a 16-bit WAV file.
        let mix = Sine.mix(Sine.make(frequency: 440, dbfs: -12, sampleRate: 48000, seconds: 2),
                           Sine.make(frequency: 1000, dbfs: -12, sampleRate: 48000, seconds: 2, phase: 1))
        let wav = WAVAudio(sampleRate: 48000, channels: 2, samples: Sine.interleave([mix, mix])).encoded(as: .pcm16)
        let decoded = try WAVAudio.decode(wav)

        let results = ToneChecker.check(decoded.channel(0), sampleRate: decoded.sampleRate,
                                        expect: [.at(440, -12), .at(1000, -12), .absent(2000)])
        XCTAssertEqual(results.map(\.passed), [true, true, true], results.map(\.description).joined(separator: "; "))
        XCTAssertEqual(results[0].measured?.frequency ?? 0, 440, accuracy: 0.1)
        XCTAssertEqual(results[1].measured?.dbfs ?? 0, -12, accuracy: 0.1)
    }

    func testFailsOnTheWrongLevelOrFrequency() {
        let tone = Sine.make(frequency: 443, dbfs: -14.5, sampleRate: 48000, seconds: 1)
        let results = ToneChecker.check(tone, sampleRate: 48000, expect: [
            .at(440, -14.5),  // 3 Hz off
            .at(443, -12),  // 2.5 dB off
            .at(443, -14),  // within 1 dB
            ToneExpectation(frequency: 443),
            .absent(443),
            .absent(1000),
        ])
        XCTAssertEqual(results.map(\.passed), [false, false, true, true, false, true],
                       results.map(\.description).joined(separator: "; "))
    }

    func testSilenceHasNoTones() {
        let silence = [Float](repeating: 0, count: 48000)
        let results = ToneChecker.check(silence, sampleRate: 48000, expect: [.at(440, -12), ToneExpectation(frequency: 440), .absent(440)])
        XCTAssertEqual(results.map(\.passed), [false, false, true])
        XCTAssertNil(results[0].measured)
        // Too short to analyse: only absence passes.
        let short = ToneChecker.check([0.5, -0.5], sampleRate: 48000, expect: [ToneExpectation(frequency: 440), .absent(440)])
        XCTAssertEqual(short.map(\.passed), [false, true])
    }

    func testPeaksListsTonesStrongestFirstWithoutSideLobes() throws {
        let mix = Sine.mix(Sine.make(frequency: 1000, dbfs: -6, sampleRate: 48000, seconds: 1),
                           Sine.make(frequency: 440, dbfs: -20, sampleRate: 48000, seconds: 1))
        let spectrum = try XCTUnwrap(Spectrum(samples: mix, sampleRate: 48000))
        let peaks = spectrum.peaks(minimumDBFS: -40)
        XCTAssertEqual(peaks.count, 2, "\(peaks)")
        XCTAssertEqual(peaks.first?.frequency ?? 0, 1000, accuracy: 0.5)
        XCTAssertEqual(peaks.first?.dbfs ?? 0, -6, accuracy: 0.1)
        XCTAssertEqual(peaks.last?.frequency ?? 0, 440, accuracy: 0.5)
        XCTAssertEqual(peaks.last?.dbfs ?? 0, -20, accuracy: 0.1)
    }

    func testResidualShowsAClick() throws {
        var tone = Sine.make(frequency: 1000, dbfs: -12, sampleRate: 48000, seconds: 1)
        let clean = try XCTUnwrap(Spectrum(samples: tone, sampleRate: 48000))
        let cleanResidual = clean.residualDBFS(excluding: clean.peaks())
        // A Hann window's far side lobes leave about -74 dBFS of a -12 dBFS tone outside its lobe.
        XCTAssertLessThan(cleanResidual, -60)
        for i in 24000..<24064 { tone[i] = 0 }  // a 64-frame dropout
        let clicked = try XCTUnwrap(Spectrum(samples: tone, sampleRate: 48000))
        let clickedResidual = clicked.residualDBFS(excluding: [try XCTUnwrap(clicked.tone(near: 1000))])
        XCTAssertGreaterThan(clickedResidual, cleanResidual + 30)
    }

    func testSignalStats() {
        let stats = SignalStats([0, 0, 0.5, -0.75, 0, 0, 0, 0.25])
        XCTAssertEqual(stats.peak, 0.75)
        XCTAssertEqual(stats.zeros, 5)
        XCTAssertEqual(stats.longestZeroRun, 3)
        XCTAssertEqual(stats.count, 8)
        XCTAssertEqual(stats.rms, ((0.25 + 0.5625 + 0.0625) / 8).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(SignalStats([]).rms, 0)
        XCTAssertEqual(ToneMeasurement(frequency: 440, amplitude: 0.5).dbfs, -6.0206, accuracy: 1e-3)
    }
}
