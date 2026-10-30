#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

namespace duette {

/// Result of a latency measurement.
struct LatencyResult {
  /// Delay of the recording relative to the reference, in frames.
  std::size_t lagFrames = 0;
  /// Normalized cross-correlation at that lag, 0..1. About 1 means the recording holds a clean
  /// copy of the reference at that lag. Uncorrelated input scores around 0.1 or less, so values
  /// above roughly 0.5 can be trusted.
  double confidence = 0.0;
};

/// Measures the delay between a known test signal and its recording by cross-correlation. Used
/// by `duettectl` and the CI integration tests to time the loopback path.
///
/// This is offline analysis, not real-time code: it allocates and takes as long as it needs.
/// Never call it from an audio thread.
class LatencyEstimator {
 public:
  /// A linear sweep from `startHz` to `endHz` over `frames` samples, with 5 % raised-cosine
  /// fades at both ends so it starts and stops without a click. Its autocorrelation has one
  /// sharp peak, so the lag is found to the sample even with noise.
  static std::vector<float> makeChirp(double sampleRate, double startHz, double endHz,
                                      std::size_t frames, float amplitude = 0.5f) {
    std::vector<float> out(frames);
    if (frames == 0) return out;
    constexpr double kPi = 3.14159265358979323846;
    const double duration = static_cast<double>(frames) / sampleRate;
    const double sweep = (endHz - startHz) / (2.0 * duration);
    const std::size_t fade = frames / 20;
    for (std::size_t i = 0; i < frames; ++i) {
      const double t = static_cast<double>(i) / sampleRate;
      double window = 1.0;
      if (i < fade) {
        window = 0.5 * (1.0 - std::cos(kPi * static_cast<double>(i) / static_cast<double>(fade)));
      } else if (i >= frames - fade) {
        window = 0.5 * (1.0 - std::cos(kPi * static_cast<double>(frames - 1 - i) / static_cast<double>(fade)));
      }
      out[i] = static_cast<float>(static_cast<double>(amplitude) * window *
                                  std::sin(2.0 * kPi * (startHz * t + sweep * t * t)));
    }
    return out;
  }

  /// Finds the lag in [0, maxLagFrames] at which `recording` best matches `reference`, that is
  /// the lag that maximizes the normalized correlation of `reference[i]` with
  /// `recording[lag + i]`. The window is clamped so the whole reference fits inside the recording;
  /// if it cannot fit at all, or either signal is empty or silent, the confidence is 0.
  /// Only positive correlation counts, so a polarity-inverted recording is not matched.
  static LatencyResult estimate(const float* reference, std::size_t referenceFrames,
                                const float* recording, std::size_t recordingFrames,
                                std::size_t maxLagFrames) {
    LatencyResult best;
    if (reference == nullptr || recording == nullptr || referenceFrames == 0 ||
        recordingFrames < referenceFrames) {
      return best;
    }

    double referenceEnergy = 0.0;
    for (std::size_t i = 0; i < referenceFrames; ++i) {
      referenceEnergy += static_cast<double>(reference[i]) * static_cast<double>(reference[i]);
    }
    if (!(referenceEnergy > 0.0)) return best;

    // energy[k] = sum of recording[j]^2 for j < k, so any window's energy is a subtraction.
    std::vector<double> energy(recordingFrames + 1, 0.0);
    for (std::size_t i = 0; i < recordingFrames; ++i) {
      energy[i + 1] = energy[i] + static_cast<double>(recording[i]) * static_cast<double>(recording[i]);
    }

    const std::size_t lastLag = recordingFrames - referenceFrames;
    const std::size_t limit = maxLagFrames < lastLag ? maxLagFrames : lastLag;
    for (std::size_t lag = 0; lag <= limit; ++lag) {
      const double windowEnergy = energy[lag + referenceFrames] - energy[lag];
      if (!(windowEnergy > 1e-20)) continue;

      double dot = 0.0;
      const float* window = recording + lag;
      for (std::size_t i = 0; i < referenceFrames; ++i) {
        dot += static_cast<double>(reference[i]) * static_cast<double>(window[i]);
      }
      const double score = dot / std::sqrt(referenceEnergy * windowEnergy);
      if (std::isfinite(score) && score > best.confidence) {
        best.confidence = score > 1.0 ? 1.0 : score;
        best.lagFrames = lag;
      }
    }
    return best;
  }

  static LatencyResult estimate(const std::vector<float>& reference, const std::vector<float>& recording,
                                std::size_t maxLagFrames) {
    return estimate(reference.data(), reference.size(), recording.data(), recording.size(), maxLagFrames);
  }
};

}  // namespace duette
