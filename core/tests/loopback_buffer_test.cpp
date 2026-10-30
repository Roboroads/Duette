#include <duette/loopback_buffer.hpp>

#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <thread>
#include <vector>

namespace {

using duette::LoopbackBuffer;

constexpr std::size_t kCap = 1024;
using Buf = LoopbackBuffer<2, kCap>;

// Every frame is a pure function of its sample time, so a reader can tell whether it got the
// right frame, a frame from another time, or half of each. Values are never 0, which keeps
// "zero frame" distinguishable from "data".
float left(std::int64_t t) { return static_cast<float>(((t % 4093) + 4093) % 4093 + 1); }
float right(std::int64_t t) { return -left(t) * 0.5f; }

std::unique_ptr<Buf> makeBuf() { return std::make_unique<Buf>(); }

void writeRange(Buf& b, std::int64_t t0, std::size_t n) {
  std::vector<float> in(n * 2);
  for (std::size_t i = 0; i < n; ++i) {
    const auto t = t0 + static_cast<std::int64_t>(i);
    in[2 * i] = left(t);
    in[2 * i + 1] = right(t);
  }
  b.write(t0, in.data(), n);
}

// Reads [t0, t0+n) and returns one flag per frame: 1 when it holds the expected data for that
// time, 0 when it is an exact zero frame. Anything else fails the check below.
std::vector<int> readRange(const Buf& b, std::int64_t t0, std::size_t n) {
  std::vector<float> out(n * 2, 7.0f);  // 7 proves every output sample gets written
  b.read(t0, out.data(), n);
  std::vector<int> flags(n, -1);
  for (std::size_t i = 0; i < n; ++i) {
    const auto t = t0 + static_cast<std::int64_t>(i);
    if (out[2 * i] == 0.0f && out[2 * i + 1] == 0.0f) {
      flags[i] = 0;
    } else if (out[2 * i] == left(t) && out[2 * i + 1] == right(t)) {
      flags[i] = 1;
    }
  }
  return flags;
}

bool allEqual(const std::vector<int>& flags, std::size_t from, std::size_t to, int value) {
  for (std::size_t i = from; i < to; ++i) {
    if (flags[i] != value) return false;
  }
  return true;
}

constexpr bool underThreadSanitizer() {
#if defined(__SANITIZE_THREAD__)
  return true;
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
  return true;
#else
  return false;
#endif
#else
  return false;
#endif
}

// How many 128-frame blocks the writer produces in the threaded test. TSan finds data races
// whatever the count, but it makes everything ~20x slower, so it gets a short run. Every other
// build gets a long one: that is what can catch a memory-ordering mistake, which x86 and TSan
// cannot show but a weakly ordered CPU (the arm64 CI job) can. DUETTE_STRESS_BLOCKS overrides
// it for longer local runs.
std::int64_t stressBlocks() {
  if (const char* env = std::getenv("DUETTE_STRESS_BLOCKS")) {
    const long long n = std::atoll(env);
    if (n > 0) return n;
  }
  return underThreadSanitizer() ? 4000 : 200000;
}

}  // namespace

TEST_CASE("read before any write gives zeros", "[loopback]") {
  auto b = makeBuf();
  CHECK(b->lastWrittenEnd() == Buf::kNothingWritten);
  std::vector<float> out(64 * 2, 7.0f);
  CHECK(b->read(0, out.data(), 64) == 0);
  for (float v : out) CHECK(v == 0.0f);
  CHECK(allEqual(readRange(*b, -100, 200), 0, 200, 0));
}

TEST_CASE("exact round trip at the same sample times", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 300);
  CHECK(b->lastWrittenEnd() == 300);

  CHECK(allEqual(readRange(*b, 0, 300), 0, 300, 1));
  // Any sub-range and any block size reads the same data: reading consumes nothing.
  CHECK(allEqual(readRange(*b, 10, 20), 0, 20, 1));
  CHECK(allEqual(readRange(*b, 299, 1), 0, 1, 1));
  CHECK(allEqual(readRange(*b, 0, 300), 0, 300, 1));
}

TEST_CASE("read returns the number of frames that held data", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 100, 100);
  std::vector<float> out(300 * 2);
  CHECK(b->read(50, out.data(), 300) == 100);
  CHECK(b->read(100, out.data(), 100) == 100);
  CHECK(b->read(200, out.data(), 10) == 0);
}

TEST_CASE("blocks written back to back read as one stream", "[loopback]") {
  auto b = makeBuf();
  std::int64_t t = 0;
  for (std::size_t n : {1u, 64u, 128u, 37u, 256u, 5u}) {
    writeRange(*b, t, n);
    t += static_cast<std::int64_t>(n);
  }
  CHECK(b->lastWrittenEnd() == t);
  CHECK(allEqual(readRange(*b, 0, static_cast<std::size_t>(t)), 0, static_cast<std::size_t>(t), 1));
}

TEST_CASE("frames at or after lastWrittenEnd read as zeros", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 100);
  const auto flags = readRange(*b, 50, 100);  // [50, 150)
  CHECK(allEqual(flags, 0, 50, 1));
  CHECK(allEqual(flags, 50, 100, 0));

  // Frames before the first write are zeros too.
  const auto early = readRange(*b, -20, 40);  // [-20, 20)
  CHECK(allEqual(early, 0, 20, 0));
  CHECK(allEqual(early, 20, 40, 1));
}

TEST_CASE("data older than the capacity reads as zeros", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 1500);
  const std::int64_t oldest = 1500 - static_cast<std::int64_t>(kCap);  // 476
  const auto flags = readRange(*b, 0, 1500);
  CHECK(allEqual(flags, 0, static_cast<std::size_t>(oldest), 0));
  CHECK(allEqual(flags, static_cast<std::size_t>(oldest), 1500, 1));
}

TEST_CASE("the capacity boundary wraps without losing frames", "[loopback]") {
  auto b = makeBuf();
  // Slots wrap at sample time 1024: this block starts in the last 24 slots and ends in the first 76.
  writeRange(*b, 1000, 100);
  CHECK(allEqual(readRange(*b, 1000, 100), 0, 100, 1));

  // Keep going past two full wraps; the newest `kCap` frames stay exact.
  std::int64_t t = 1100;
  while (t < 3 * static_cast<std::int64_t>(kCap) + 17) {
    writeRange(*b, t, 61);
    t += 61;
  }
  const auto flags = readRange(*b, t - static_cast<std::int64_t>(kCap), kCap);
  CHECK(allEqual(flags, 0, kCap, 1));
  // One frame further back is already gone.
  CHECK(readRange(*b, t - static_cast<std::int64_t>(kCap) - 1, 1)[0] == 0);
}

TEST_CASE("a write larger than the capacity keeps the newest frames", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 3000);
  CHECK(b->lastWrittenEnd() == 3000);
  const auto flags = readRange(*b, 0, 3000);
  CHECK(allEqual(flags, 0, 3000 - kCap, 0));
  CHECK(allEqual(flags, 3000 - kCap, 3000, 1));
}

TEST_CASE("a writer that restarts later leaves zeros in the gap", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 100);
  writeRange(*b, 300, 100);  // 200 frames never written
  CHECK(b->lastWrittenEnd() == 400);
  const auto flags = readRange(*b, 0, 400);
  CHECK(allEqual(flags, 0, 100, 1));
  CHECK(allEqual(flags, 100, 300, 0));
  CHECK(allEqual(flags, 300, 400, 1));

  // A gap longer than the capacity also leaves nothing readable behind it.
  writeRange(*b, 10000, 100);
  CHECK(allEqual(readRange(*b, 0, 400), 0, 400, 0));
  CHECK(allEqual(readRange(*b, 9000, 1100), 0, 1000, 0));
  CHECK(allEqual(readRange(*b, 10000, 100), 0, 100, 1));
}

TEST_CASE("a writer that goes back in time starts a new timeline", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, 0, 500);
  writeRange(*b, 100, 100);  // restart at an earlier sample time
  CHECK(b->lastWrittenEnd() == 200);
  const auto flags = readRange(*b, 0, 500);
  CHECK(allEqual(flags, 0, 100, 0));    // old timeline is gone
  CHECK(allEqual(flags, 100, 200, 1));  // new data
  CHECK(allEqual(flags, 200, 500, 0));  // nothing newer than the new end

  writeRange(*b, 200, 50);  // and it continues from there
  CHECK(allEqual(readRange(*b, 100, 150), 0, 150, 1));
}

TEST_CASE("an old timeline never comes back, however many times the writer rewinds", "[loopback]") {
  using Small = LoopbackBuffer<2, 64>;
  Small b;
  auto fill = [&](std::int64_t t0, std::size_t n) {
    std::vector<float> in(n * 2);
    for (std::size_t i = 0; i < n; ++i) {
      const auto t = t0 + static_cast<std::int64_t>(i);
      in[2 * i] = left(t);
      in[2 * i + 1] = right(t);
    }
    b.write(t0, in.data(), n);
  };

  fill(0, 64);  // timeline 0 fills every slot

  // Each of these starts a new timeline at the same place, touching only slot 0, so slots 1..63
  // keep the frames of timeline 0. 65536 rewinds is enough to wrap any generation counter up to
  // 16 bits, and the 15-bit one the buffer used to have wraps twice.
  for (int i = 0; i < 65536; ++i) fill(0, 1);

  // Move the end forward without writing slots 1..63, so that they fall inside the readable window.
  fill(64, 1);
  REQUIRE(b.lastWrittenEnd() == 65);

  std::vector<float> out(63 * 2, 7.0f);
  CHECK(b.read(1, out.data(), 63) == 0);  // frames 1..63 were never written in this timeline
  for (float v : out) REQUIRE(v == 0.0f);
}

TEST_CASE("zero-length reads and writes do nothing", "[loopback]") {
  auto b = makeBuf();
  b->write(0, nullptr, 0);
  CHECK(b->lastWrittenEnd() == Buf::kNothingWritten);
  writeRange(*b, 0, 10);
  float sentinel = 7.0f;
  CHECK(b->read(0, &sentinel, 0) == 0);
  CHECK(sentinel == 7.0f);
}

TEST_CASE("negative sample times work", "[loopback]") {
  auto b = makeBuf();
  writeRange(*b, -50, 100);
  CHECK(b->lastWrittenEnd() == 50);
  CHECK(allEqual(readRange(*b, -50, 100), 0, 100, 1));
}

TEST_CASE("mono and wide buffers keep channels apart", "[loopback]") {
  LoopbackBuffer<1, 64> mono;
  const float in1[3] = {0.25f, -0.5f, 0.75f};
  mono.write(5, in1, 3);
  float out1[5] = {};
  CHECK(mono.read(4, out1, 5) == 3);
  CHECK(out1[0] == 0.0f);
  CHECK(out1[1] == 0.25f);
  CHECK(out1[3] == 0.75f);
  CHECK(out1[4] == 0.0f);

  LoopbackBuffer<4, 64> wide;
  const float in4[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  wide.write(0, in4, 2);
  float out4[8] = {};
  CHECK(wide.read(0, out4, 2) == 2);
  for (int i = 0; i < 8; ++i) CHECK(out4[i] == in4[i]);
}

TEST_CASE("one writer and two readers never see torn or misplaced frames", "[loopback][threads]") {
  auto b = makeBuf();
  constexpr std::int64_t kBlock = 128;
  const std::int64_t kBlocks = stressBlocks();
  constexpr std::size_t kReadFrames = 96;

  std::atomic<bool> done{false};
  struct Result {
    std::uint64_t reads = 0;
    std::uint64_t validFrames = 0;
    std::uint64_t badFrames = 0;
  };

  // `behind` is how far (in frames) the reader's block starts before the write head. The head
  // reader stays in published, untouched data; the edge reader reads right where the writer is
  // about to recycle slots, so its frames are valid only if no overwrite overlapped the read.
  auto reader = [&](std::int64_t behind, Result& res) {
    std::vector<float> out(kReadFrames * 2);
    while (!done.load(std::memory_order_acquire)) {
      const std::int64_t end = b->lastWrittenEnd();
      if (end == Buf::kNothingWritten) continue;
      const std::int64_t t0 = end - behind;
      b->read(t0, out.data(), kReadFrames);
      ++res.reads;
      for (std::size_t i = 0; i < kReadFrames; ++i) {
        const auto t = t0 + static_cast<std::int64_t>(i);
        const float l = out[2 * i];
        const float r = out[2 * i + 1];
        if (l == 0.0f && r == 0.0f) continue;
        if (l == left(t) && r == right(t)) {
          ++res.validFrames;
        } else {
          ++res.badFrames;
        }
      }
    }
  };

  Result head;
  Result edge;
  std::thread headReader(reader, 2 * static_cast<std::int64_t>(kReadFrames), std::ref(head));
  std::thread edgeReader(reader, static_cast<std::int64_t>(kCap) - 8, std::ref(edge));

  std::thread writer([&] {
    std::vector<float> in(static_cast<std::size_t>(kBlock) * 2);
    for (std::int64_t blk = 0; blk < kBlocks; ++blk) {
      const std::int64_t t0 = blk * kBlock;
      for (std::int64_t i = 0; i < kBlock; ++i) {
        in[static_cast<std::size_t>(2 * i)] = left(t0 + i);
        in[static_cast<std::size_t>(2 * i + 1)] = right(t0 + i);
      }
      b->write(t0, in.data(), static_cast<std::size_t>(kBlock));
      if (blk % 4 == 0) std::this_thread::yield();
    }
    done.store(true, std::memory_order_release);
  });

  writer.join();
  headReader.join();
  edgeReader.join();

  INFO("head reader: " << head.reads << " reads, " << head.validFrames << " valid frames");
  INFO("edge reader: " << edge.reads << " reads, " << edge.validFrames << " valid frames");
  CHECK(head.badFrames == 0);
  CHECK(edge.badFrames == 0);
  CHECK(head.reads > 0);
  CHECK(head.validFrames > 0);
  // The edge reader sits where the writer recycles slots, so frames there are valid only when
  // no overwrite overlapped the read. Seeing some means the test really raced the writer; seeing
  // none would mean it checked nothing.
  CHECK(edge.reads > 0);
  CHECK(edge.validFrames > 0);
}
