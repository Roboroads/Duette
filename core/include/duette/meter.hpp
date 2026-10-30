#pragma once

#include <atomic>
#include <cmath>
#include <cstddef>

#include "audio_view.hpp"

namespace duette {

/// Peak and RMS level of the most recent block, published for another thread to read.
///
/// The audio thread calls `update` once per block; each call replaces the previous reading (no
/// hold, no decay). The UI polls `peak()` and `rms()` and applies its own decay and peak hold.
/// Both values are linear amplitude (1.0 is full scale). RMS is over every sample of the block,
/// all channels together. Non-finite samples count as 0.
///
/// One writer thread, any number of readers. The two values are separate relaxed atomics, so a
/// reader may pair the peak of one block with the RMS of the next; for a meter that is harmless.
class PeakRmsMeter {
  static_assert(std::atomic<float>::is_always_lock_free, "the real-time path must not take locks");

 public:
  /// Measures `count` samples that lie `stride` floats apart. With the default stride this is
  /// any contiguous run of samples, such as a whole interleaved block with all its channels.
  /// A call with no samples leaves the reading unchanged.
  void update(const float* samples, std::size_t count, std::size_t stride = 1) noexcept {
    if (samples == nullptr || count == 0) return;
    Sums sums;
    sums.add(samples, count, stride);
    publish(sums);
  }

  /// Measures `frames` frames of every channel of `source`. A source without channels reads as
  /// silence.
  void update(const SourceView& source, std::size_t frames) noexcept {
    if (frames == 0) return;
    Sums sums;
    for (std::size_t c = 0; c < source.channels(); ++c) {
      for (std::size_t f = 0; f < frames; ++f) sums.addOne(source.at(c, f));
    }
    sums.count = frames * (source.channels() > 0 ? source.channels() : 1);
    publish(sums);
  }

  float peak() const noexcept { return peak_.load(std::memory_order_relaxed); }
  float rms() const noexcept { return rms_.load(std::memory_order_relaxed); }

 private:
  struct Sums {
    float peak = 0.0f;
    double sumSquares = 0.0;
    std::size_t count = 0;

    void addOne(float x) noexcept {
      if (!std::isfinite(x)) return;
      const float a = std::fabs(x);
      if (a > peak) peak = a;
      sumSquares += static_cast<double>(x) * static_cast<double>(x);
    }

    void add(const float* samples, std::size_t n, std::size_t stride) noexcept {
      for (std::size_t i = 0; i < n; ++i) addOne(samples[i * stride]);
      count += n;
    }
  };

  void publish(const Sums& sums) noexcept {
    const double mean = sums.count > 0 ? sums.sumSquares / static_cast<double>(sums.count) : 0.0;
    peak_.store(sums.peak, std::memory_order_relaxed);
    rms_.store(static_cast<float>(std::sqrt(mean)), std::memory_order_relaxed);
  }

  std::atomic<float> peak_{0.0f};
  std::atomic<float> rms_{0.0f};
};

}  // namespace duette
