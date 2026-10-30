#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace duette {

/// Time-indexed ring buffer that carries audio from one writer to any number of readers.
///
/// Frames are addressed by absolute sample time: the frame for time `t` lives in slot
/// `t mod CapacityPow2`. The writer (the hidden "Duette Sink" output) stores frames at the
/// sample times the HAL gives it, and each reader (the visible "Duette" input) asks for the
/// frames at the sample times it needs. Nothing is consumed by reading, so several readers can
/// read the same range.
///
/// A reader gets real data for a frame only when that exact frame was written and has not been
/// overwritten since. Everything else reads as an exact zero frame:
///   - time at or after `lastWrittenEnd()`: the writer has not got there yet (underrun, or the
///     app is not running);
///   - time older than `lastWrittenEnd() - CapacityPow2`: overwritten by newer data (stale);
///   - times the writer skipped when it restarted later: a gap.
///
/// Threading: exactly one thread may call `write`; any number of threads may call `read` and
/// `lastWrittenEnd`. All three are wait-free, allocate nothing, take no locks and never throw.
///
/// How readers stay consistent without locks: every slot carries a tag naming the sample time
/// (and timeline generation) of the frame it holds. The writer clears the tags of the slots it
/// is about to reuse, writes the samples, then publishes the new tags with release stores. A
/// reader accepts a frame only if the tag matches the time it wants both before and after it
/// copied the samples, so a frame that was recycled while being read is returned as zeros
/// rather than as a mix of two frames. That makes the "no torn frames" guarantee independent of
/// how far behind the writer a reader is.
///
/// Going back in time (a write that starts before the end of the previous one, for example when
/// a device restarts its sample clock) begins a new timeline: the previous timeline stops being
/// readable at once, and the new one starts at the first frame written. Moving forward over a
/// gap does not do that, so readers that are still behind the gap keep their data.
///
/// The object is large (about `CapacityPow2 * (8 + 4 * Channels)` bytes, 256 KiB for 2 channels
/// and 16384 frames): keep it in static or heap storage, never on a thread stack. Samples are
/// interleaved.
template <std::size_t Channels, std::size_t CapacityPow2>
class LoopbackBuffer {
  static_assert(Channels >= 1, "need at least one channel");
  static_assert(CapacityPow2 >= 2 && (CapacityPow2 & (CapacityPow2 - 1)) == 0,
                "capacity must be a power of two");
  static_assert(std::atomic<float>::is_always_lock_free &&
                    std::atomic<std::uint64_t>::is_always_lock_free &&
                    std::atomic<std::int64_t>::is_always_lock_free,
                "the real-time path must not take locks");

 public:
  /// Value of `lastWrittenEnd()` before the first write.
  static constexpr std::int64_t kNothingWritten = std::numeric_limits<std::int64_t>::min();

  static constexpr std::size_t kChannels = Channels;
  static constexpr std::size_t kCapacity = CapacityPow2;

  LoopbackBuffer() noexcept {
    for (Slot& slot : slots_) {
      slot.tag.store(kInvalidTag, std::memory_order_relaxed);
      for (auto& sample : slot.sample) sample.store(0.0f, std::memory_order_relaxed);
    }
  }

  LoopbackBuffer(const LoopbackBuffer&) = delete;
  LoopbackBuffer& operator=(const LoopbackBuffer&) = delete;

  /// Writer only. Stores `frames` interleaved frames so that the first one has sample time
  /// `sampleTime`. A block longer than the capacity keeps only its newest `CapacityPow2` frames.
  void write(std::int64_t sampleTime, const float* interleaved, std::size_t frames) noexcept {
    if (frames == 0 || interleaved == nullptr) return;

    const std::int64_t end = sampleTime + static_cast<std::int64_t>(frames);
    if (frames > CapacityPow2) {
      const std::size_t skip = frames - CapacityPow2;
      sampleTime += static_cast<std::int64_t>(skip);
      interleaved += skip * Channels;
      frames = CapacityPow2;
    }

    std::uint64_t generation = generation_.load(std::memory_order_relaxed);
    const std::int64_t previousEnd = end_.load(std::memory_order_relaxed);
    if (previousEnd != kNothingWritten && sampleTime < previousEnd) {
      generation = (generation + 1) & kGenerationMask;
      generation_.store(generation, std::memory_order_release);
    }

    // 1. Retire the frames being replaced. Readers that already copied one of them will see its
    //    tag change when they check again.
    for (std::size_t i = 0; i < frames; ++i) {
      slotFor(sampleTime + static_cast<std::int64_t>(i))
          .tag.store(kInvalidTag, std::memory_order_relaxed);
    }
    // 2. Store the samples. Release keeps every store above visible before any of these.
    for (std::size_t i = 0; i < frames; ++i) {
      Slot& slot = slotFor(sampleTime + static_cast<std::int64_t>(i));
      for (std::size_t c = 0; c < Channels; ++c) {
        slot.sample[c].store(interleaved[i * Channels + c], std::memory_order_release);
      }
    }
    // 3. Publish. Release makes the samples visible to a reader that sees the tag.
    for (std::size_t i = 0; i < frames; ++i) {
      const std::int64_t t = sampleTime + static_cast<std::int64_t>(i);
      slotFor(t).tag.store(makeTag(generation, t), std::memory_order_release);
    }
    end_.store(end, std::memory_order_release);
  }

  /// Any thread. Fills `out` with `frames` interleaved frames for sample times
  /// `[sampleTime, sampleTime + frames)`; frames without valid data become zeros. Returns how
  /// many frames held data.
  std::size_t read(std::int64_t sampleTime, float* out, std::size_t frames) const noexcept {
    if (frames == 0 || out == nullptr) return 0;

    const std::int64_t end = end_.load(std::memory_order_acquire);
    const std::uint64_t generation = generation_.load(std::memory_order_acquire);

    // Only times in [end - capacity, end) can hold data. Frames before that window are stale and
    // frames at or after `end` are an underrun; both read as zeros.
    std::size_t first = 0;       // first frame of the request inside the window
    std::size_t candidates = 0;  // one past the last frame of the request inside the window
    if (end != kNothingWritten) {
      const std::uint64_t uStart = static_cast<std::uint64_t>(sampleTime);
      const std::uint64_t uEnd = static_cast<std::uint64_t>(end);
      const std::uint64_t uOldest = uEnd - CapacityPow2;
      if (end > sampleTime) {
        const std::uint64_t ahead = uEnd - uStart;
        candidates = ahead < frames ? static_cast<std::size_t>(ahead) : frames;
        if (static_cast<std::int64_t>(uOldest) > sampleTime) {
          const std::uint64_t behind = uOldest - uStart;
          first = behind < candidates ? static_cast<std::size_t>(behind) : candidates;
        }
      }
    }

    for (std::size_t i = 0; i < first * Channels; ++i) out[i] = 0.0f;

    std::size_t valid = 0;
    float frame[Channels];
    for (std::size_t i = first; i < candidates; ++i) {
      const std::int64_t t = sampleTime + static_cast<std::int64_t>(i);
      const Slot& slot = slotFor(t);
      const std::uint64_t want = makeTag(generation, t);

      bool ok = slot.tag.load(std::memory_order_acquire) == want;
      if (ok) {
        // Acquire keeps the re-check below from being satisfied before these loads.
        for (std::size_t c = 0; c < Channels; ++c) {
          frame[c] = slot.sample[c].load(std::memory_order_acquire);
        }
        ok = slot.tag.load(std::memory_order_relaxed) == want;
      }

      for (std::size_t c = 0; c < Channels; ++c) {
        out[i * Channels + c] = ok ? frame[c] : 0.0f;
      }
      valid += ok ? 1u : 0u;
    }
    for (std::size_t i = candidates * Channels; i < frames * Channels; ++i) out[i] = 0.0f;
    return valid;
  }

  /// Any thread. One past the sample time of the newest published frame, or `kNothingWritten`.
  std::int64_t lastWrittenEnd() const noexcept { return end_.load(std::memory_order_acquire); }

 private:
  // Tag layout: bit 63 = invalid, bits 48..62 = timeline generation, bits 0..47 = sample time.
  static constexpr std::uint64_t kInvalidTag = std::uint64_t{1} << 63;
  static constexpr std::uint64_t kGenerationMask = 0x7FFF;
  static constexpr std::uint64_t kTimeMask = (std::uint64_t{1} << 48) - 1;

  static constexpr std::uint64_t makeTag(std::uint64_t generation, std::int64_t sampleTime) noexcept {
    return (generation << 48) | (static_cast<std::uint64_t>(sampleTime) & kTimeMask);
  }

  struct Slot {
    std::atomic<std::uint64_t> tag;
    std::array<std::atomic<float>, Channels> sample;
  };

  Slot& slotFor(std::int64_t sampleTime) noexcept {
    return slots_[static_cast<std::size_t>(static_cast<std::uint64_t>(sampleTime) & (CapacityPow2 - 1))];
  }
  const Slot& slotFor(std::int64_t sampleTime) const noexcept {
    return slots_[static_cast<std::size_t>(static_cast<std::uint64_t>(sampleTime) & (CapacityPow2 - 1))];
  }

  alignas(64) std::atomic<std::int64_t> end_{kNothingWritten};
  alignas(64) std::atomic<std::uint64_t> generation_{0};
  alignas(64) std::array<Slot, CapacityPow2> slots_;
};

}  // namespace duette
