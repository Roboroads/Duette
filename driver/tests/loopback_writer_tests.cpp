// Tests for LoopbackWriter: the sink's guard around LoopbackBuffer::write. No Apple headers.
#include "LoopbackWriter.hpp"

#include <duette/loopback_buffer.hpp>

#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <thread>
#include <vector>

using duette::driver::LoopbackWriter;
using WriteResult = duette::driver::LoopbackWriteResult;

namespace {

constexpr std::size_t kCapacity = 4096;
using Buffer = duette::LoopbackBuffer<2, kCapacity>;

// The value both channels of the frame at sample time t carry.
float valueAt(std::int64_t t) { return static_cast<float>(t % 1000) / 1000.0f + 0.001f; }

std::vector<float> block(std::int64_t start, std::size_t frames) {
  std::vector<float> v(frames * 2);
  for (std::size_t i = 0; i < frames; ++i) {
    v[i * 2] = v[i * 2 + 1] = valueAt(start + static_cast<std::int64_t>(i));
  }
  return v;
}

WriteResult writeBlock(LoopbackWriter<Buffer>& w, std::int64_t start, std::size_t frames) {
  const std::vector<float> data = block(start, frames);
  return w.write(start, data.data(), frames);
}

// Frames in [start, start + frames) that read back with their own value.
std::size_t intactFrames(const Buffer& b, std::int64_t start, std::size_t frames) {
  std::vector<float> out(frames * 2);
  b.read(start, out.data(), frames);
  std::size_t intact = 0;
  for (std::size_t i = 0; i < frames; ++i) {
    const float want = valueAt(start + static_cast<std::int64_t>(i));
    if (out[i * 2] == want && out[i * 2 + 1] == want) ++intact;
  }
  return intact;
}

}  // namespace

TEST_CASE("consecutive blocks are written as they are") {
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  for (std::int64_t t = 0; t < 2048; t += 128) {
    REQUIRE(writeBlock(writer, t, 128) == WriteResult::Written);
  }
  CHECK(intactFrames(*buffer, 0, 2048) == 2048);
  const auto stats = writer.stats();
  CHECK(stats.written == 16);
  CHECK(stats.trimmed == 0);
  CHECK(stats.droppedOverlap == 0);
  CHECK(stats.droppedBusy == 0);
}

TEST_CASE("a block that repeats sample times already written is dropped, not a new timeline") {
  // Two IO contexts writing the sink for the same cycles. LoopbackBuffer alone would treat each
  // repeat as a clock rewind and blank everything "Duette" could still read.
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  for (std::int64_t t = 0; t < 2048; t += 128) {
    REQUIRE(writeBlock(writer, t, 128) == WriteResult::Written);
    REQUIRE(writeBlock(writer, t, 128) == WriteResult::DroppedOverlap);  // the second writer
  }
  CHECK(intactFrames(*buffer, 0, 2048) == 2048);
  CHECK(writer.stats().droppedOverlap == 16);
}

TEST_CASE("a block that starts inside the written range keeps only its new tail") {
  // For example IO restarting within one buffer: the new first block overlaps the old end.
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  REQUIRE(writeBlock(writer, 0, 512) == WriteResult::Written);
  REQUIRE(writeBlock(writer, 448, 128) == WriteResult::Trimmed);  // 448..512 old, 512..576 new
  CHECK(buffer->lastWrittenEnd() == 576);
  CHECK(intactFrames(*buffer, 0, 576) == 576);
  CHECK(writer.stats().trimmed == 1);
}

TEST_CASE("a block far behind the written range is dropped") {
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  REQUIRE(writeBlock(writer, 100000, 128) == WriteResult::Written);
  CHECK(writeBlock(writer, 0, 128) == WriteResult::DroppedOverlap);
  CHECK(buffer->lastWrittenEnd() == 100128);
  CHECK(intactFrames(*buffer, 100000, 128) == 128);
}

TEST_CASE("a gap forward is written normally") {
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  REQUIRE(writeBlock(writer, 0, 128) == WriteResult::Written);
  REQUIRE(writeBlock(writer, 1000, 128) == WriteResult::Written);
  CHECK(intactFrames(*buffer, 0, 128) == 128);
  CHECK(intactFrames(*buffer, 1000, 128) == 128);
}

TEST_CASE("empty and null blocks are ignored") {
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  const std::vector<float> data = block(0, 4);
  CHECK(writer.write(0, data.data(), 0) == WriteResult::Ignored);
  CHECK(writer.write(0, nullptr, 4) == WriteResult::Ignored);
  CHECK(buffer->lastWrittenEnd() == Buffer::kNothingWritten);
}

namespace {

// A buffer that, in the middle of a write, lets a test act as a second IO thread arriving at the
// same moment.
struct ReentrantBuffer {
  static constexpr std::int64_t kNothingWritten = Buffer::kNothingWritten;
  static constexpr std::size_t kChannels = 2;
  std::int64_t end = kNothingWritten;
  std::function<void()> duringWrite;
  int writes = 0;

  std::int64_t lastWrittenEnd() const noexcept { return end; }
  void write(std::int64_t sampleTime, const float*, std::size_t frames) noexcept {
    ++writes;
    if (duringWrite) {
      auto hook = std::move(duringWrite);
      duringWrite = nullptr;
      hook();
    }
    end = sampleTime + static_cast<std::int64_t>(frames);
  }
};

}  // namespace

TEST_CASE("a write that arrives while another is in progress is dropped and counted") {
  ReentrantBuffer buffer;
  LoopbackWriter<ReentrantBuffer> writer(buffer);
  const std::vector<float> data(256, 0.5f);
  WriteResult second = WriteResult::Written;
  buffer.duringWrite = [&] { second = writer.write(1000, data.data(), 128); };

  CHECK(writer.write(0, data.data(), 128) == WriteResult::Written);
  CHECK(second == WriteResult::DroppedBusy);
  CHECK(buffer.writes == 1);
  CHECK(writer.stats().droppedBusy == 1);

  // The guard is released afterwards.
  CHECK(writer.write(128, data.data(), 128) == WriteResult::Written);
  CHECK(buffer.writes == 2);
}

TEST_CASE("two threads writing the same cycles never blank the buffer") {
  auto buffer = std::make_unique<Buffer>();
  LoopbackWriter<Buffer> writer(*buffer);
  constexpr std::size_t kFrames = 64;
  constexpr std::size_t kCycles = kCapacity / kFrames;  // everything stays inside the window
  std::vector<WriteResult> resultsA(kCycles), resultsB(kCycles);
  std::atomic<bool> go{false};
  auto run = [&](std::vector<WriteResult>& results) {
    while (!go.load()) {
    }
    for (std::size_t c = 0; c < kCycles; ++c) {
      results[c] = writeBlock(writer, static_cast<std::int64_t>(c * kFrames), kFrames);
    }
  };
  std::thread a(run, std::ref(resultsA)), b(run, std::ref(resultsB));
  go = true;
  a.join();
  b.join();

  // A cycle both threads dropped is a gap, which is allowed. A cycle one of them wrote must still
  // be readable: nothing may start a new timeline and retire it.
  std::size_t written = 0;
  for (std::size_t c = 0; c < kCycles; ++c) {
    const bool wrote = resultsA[c] == WriteResult::Written || resultsB[c] == WriteResult::Written;
    if (!wrote) continue;
    ++written;
    REQUIRE(intactFrames(*buffer, static_cast<std::int64_t>(c * kFrames), kFrames) == kFrames);
  }
  CHECK(written > 0);
  const auto s = writer.stats();
  CHECK(s.written == written);
  CHECK(s.written + s.trimmed + s.droppedOverlap + s.droppedBusy == 2 * kCycles);
}
