#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

#include "audio_view.hpp"

namespace duette {

/// Counts how many frames in a row were exactly silent.
///
/// A frame is silent when every channel of it is exactly 0.0 (including -0.0). A single other
/// sample, however small, ends the run. Core Audio hands a process tap an all-zero stream when
/// capture permission is denied, so a long run on the tap while the device is running is the
/// sign to show the "check permission" hint. An app that is paused or silent also produces exact
/// zeros, so the caller decides how long a run has to be before it means anything.
///
/// One writer thread (the audio thread) calls `update`; any thread may read `zeroFrames()`.
class ZeroRunDetector {
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                "the real-time path must not take locks");

 public:
  /// Feeds `frames` interleaved frames of `channels` channels. Null data or zero channels carry
  /// no information and change nothing.
  void update(const float* interleaved, std::size_t frames, std::size_t channels) noexcept {
    if (interleaved == nullptr || channels == 0 || frames == 0) return;
    std::uint64_t run = run_.load(std::memory_order_relaxed);
    for (std::size_t f = 0; f < frames; ++f) {
      bool silent = true;
      for (std::size_t c = 0; c < channels; ++c) {
        if (interleaved[f * channels + c] != 0.0f) {
          silent = false;
          break;
        }
      }
      run = silent ? run + 1 : 0;
    }
    run_.store(run, std::memory_order_relaxed);
  }

  /// Same, for a source in any layout. A view without channels changes nothing.
  void update(const SourceView& source, std::size_t frames) noexcept {
    const std::size_t channels = source.channels();
    if (channels == 0 || frames == 0) return;
    std::uint64_t run = run_.load(std::memory_order_relaxed);
    for (std::size_t f = 0; f < frames; ++f) {
      bool silent = true;
      for (std::size_t c = 0; c < channels; ++c) {
        if (source.at(c, f) != 0.0f) {
          silent = false;
          break;
        }
      }
      run = silent ? run + 1 : 0;
    }
    run_.store(run, std::memory_order_relaxed);
  }

  /// Length of the current run of silent frames, ending at the newest frame seen.
  std::uint64_t zeroFrames() const noexcept { return run_.load(std::memory_order_relaxed); }

  /// Forgets the run. Call from the audio thread, or while it is stopped.
  void reset() noexcept { run_.store(0, std::memory_order_relaxed); }

 private:
  std::atomic<std::uint64_t> run_{0};
};

}  // namespace duette
