#pragma once

// The sink's side of the loopback. No Apple headers, so it is tested on Linux.

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace duette::driver {

enum class LoopbackWriteResult {
  Written,         // the whole block went in
  Trimmed,         // it started inside what was already written; only the new tail went in
  DroppedOverlap,  // every frame of it was already written (or it is older than that)
  DroppedBusy,     // another IO context was writing at that moment
  Ignored,         // empty block or no data
};

/// Writes the sink's IO blocks into a LoopbackBuffer while keeping that buffer's single-writer
/// contract, whoever calls it.
///
/// More than one IO context can drive "Duette Sink" at once: the app's aggregate and a direct
/// client such as duettectl, two app instances, or the HAL restarting IO before the old cycle is
/// done. Each calls WriteMix for its own cycles, possibly on its own thread. Two problems follow:
///
///  - LoopbackBuffer allows one writer only. A try-acquired flag serializes the writers; a block
///    that finds the flag taken is dropped (and counted) rather than waiting on the IO thread.
///  - A block that starts before the end of what is already written looks to LoopbackBuffer like
///    the clock going back, and it starts a new timeline, which blanks everything "Duette" could
///    still read. The plug-in's clock never goes back, so such a block is a duplicate: frames
///    already written are skipped and only a new tail, if any, is written.
///
/// Wait-free, allocation-free and lock-free: safe on any IO thread. `Buffer` is a LoopbackBuffer
/// (or anything with its `write` and `lastWrittenEnd`).
template <typename Buffer>
class LoopbackWriter {
 public:
  struct Stats {
    std::uint64_t written = 0;
    std::uint64_t trimmed = 0;
    std::uint64_t droppedOverlap = 0;
    std::uint64_t droppedBusy = 0;
  };

  explicit LoopbackWriter(Buffer& buffer) noexcept : buffer_(buffer) {}

  LoopbackWriteResult write(std::int64_t sampleTime, const float* interleaved,
                            std::size_t frames) noexcept {
    if (frames == 0 || interleaved == nullptr) return LoopbackWriteResult::Ignored;

    if (busy_.exchange(true, std::memory_order_acquire)) {
      droppedBusy_.fetch_add(1, std::memory_order_relaxed);
      return LoopbackWriteResult::DroppedBusy;
    }

    LoopbackWriteResult result = LoopbackWriteResult::Written;
    const std::int64_t end = buffer_.lastWrittenEnd();
    const std::int64_t blockEnd = sampleTime + static_cast<std::int64_t>(frames);
    if (end != Buffer::kNothingWritten && sampleTime < end) {
      if (blockEnd <= end) {
        result = LoopbackWriteResult::DroppedOverlap;
      } else {
        const auto skip = static_cast<std::size_t>(end - sampleTime);
        buffer_.write(end, interleaved + skip * kChannels, frames - skip);
        result = LoopbackWriteResult::Trimmed;
      }
    } else {
      buffer_.write(sampleTime, interleaved, frames);
    }

    busy_.store(false, std::memory_order_release);

    switch (result) {
      case LoopbackWriteResult::Written: written_.fetch_add(1, std::memory_order_relaxed); break;
      case LoopbackWriteResult::Trimmed: trimmed_.fetch_add(1, std::memory_order_relaxed); break;
      case LoopbackWriteResult::DroppedOverlap:
        droppedOverlap_.fetch_add(1, std::memory_order_relaxed);
        break;
      default: break;
    }
    return result;
  }

  Stats stats() const noexcept {
    Stats s;
    s.written = written_.load(std::memory_order_relaxed);
    s.trimmed = trimmed_.load(std::memory_order_relaxed);
    s.droppedOverlap = droppedOverlap_.load(std::memory_order_relaxed);
    s.droppedBusy = droppedBusy_.load(std::memory_order_relaxed);
    return s;
  }

 private:
  static constexpr std::size_t kChannels = Buffer::kChannels;
  static_assert(std::atomic<bool>::is_always_lock_free, "the IO path must not take locks");

  Buffer& buffer_;
  std::atomic<bool> busy_{false};
  std::atomic<std::uint64_t> written_{0};
  std::atomic<std::uint64_t> trimmed_{0};
  std::atomic<std::uint64_t> droppedOverlap_{0};
  std::atomic<std::uint64_t> droppedBusy_{0};
};

}  // namespace duette::driver
