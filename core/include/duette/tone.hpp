#pragma once

#include <cmath>
#include <cstddef>

namespace duette {

/// Sine generator with a phase accumulator, for the self-test tone and for CI.
///
/// The phase is kept as a double number of cycles in [0, 1), so it stays exact over hours, and
/// it carries over from one call to the next: blocks of any size join without a click, and
/// changing the frequency mid-stream bends the phase instead of jumping. Output starts at phase
/// 0 (a sample of exactly 0).
///
/// There is no built-in fade: changing the amplitude takes effect on the next sample. To switch
/// the tone on and off without clicks, multiply it by a `SmoothedGain`.
///
/// Not thread-safe; use it from the audio thread only.
class ToneGenerator {
 public:
  explicit ToneGenerator(float sampleRate = 48000.0f, float frequencyHz = 1000.0f,
                         float amplitude = 0.5f) noexcept
      : sampleRate_(static_cast<double>(sampleRate > 0.0f ? sampleRate : 48000.0f)) {
    setFrequency(frequencyHz);
    setAmplitude(amplitude);
  }

  /// Sets the frequency, limited to 0..Nyquist. NaN and infinity are ignored.
  void setFrequency(float hz) noexcept {
    if (!std::isfinite(hz)) return;
    const double nyquist = sampleRate_ / 2.0;
    double f = static_cast<double>(hz);
    f = f < 0.0 ? 0.0 : (f > nyquist ? nyquist : f);
    frequency_ = f;
    increment_ = f / sampleRate_;
  }

  /// Sets the amplitude (linear, peak). Negative values count as 0. NaN and infinity are ignored.
  void setAmplitude(float amplitude) noexcept {
    if (!std::isfinite(amplitude)) return;
    amplitude_ = amplitude > 0.0f ? amplitude : 0.0f;
  }

  float frequency() const noexcept { return static_cast<float>(frequency_); }
  float amplitude() const noexcept { return amplitude_; }

  /// Back to phase 0.
  void reset() noexcept { phase_ = 0.0; }

  /// Next sample.
  float next() noexcept {
    const float sample = amplitude_ * static_cast<float>(std::sin(kTwoPi * phase_));
    phase_ += increment_;
    if (phase_ >= 1.0) phase_ -= 1.0;
    return sample;
  }

  /// Writes `frames` interleaved frames; every channel of a frame gets the same sample.
  void fill(float* out, std::size_t frames, std::size_t channels = 1) noexcept {
    if (out == nullptr) return;
    for (std::size_t f = 0; f < frames; ++f) {
      const float sample = next();
      for (std::size_t c = 0; c < channels; ++c) out[f * channels + c] = sample;
    }
  }

 private:
  static constexpr double kTwoPi = 6.283185307179586476925286766559;

  double sampleRate_;
  double frequency_ = 0.0;
  double increment_ = 0.0;  // cycles per sample
  double phase_ = 0.0;      // cycles, [0, 1)
  float amplitude_ = 0.0f;
};

}  // namespace duette
