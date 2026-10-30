#include <duette/audio_view.hpp>
#include <duette/zero_run.hpp>

#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cstdint>
#include <limits>
#include <thread>
#include <vector>

using duette::SourceView;
using duette::ZeroRunDetector;

TEST_CASE("a new detector has seen no zeros", "[zero_run]") {
  ZeroRunDetector d;
  CHECK(d.zeroFrames() == 0);
}

TEST_CASE("silent frames add up across blocks", "[zero_run]") {
  ZeroRunDetector d;
  const std::vector<float> silence(100 * 2, 0.0f);  // 100 stereo frames
  d.update(silence.data(), 100, 2);
  CHECK(d.zeroFrames() == 100);
  d.update(silence.data(), 50, 2);
  CHECK(d.zeroFrames() == 150);
  d.update(silence.data(), 0, 2);
  CHECK(d.zeroFrames() == 150);
}

TEST_CASE("any nonzero sample resets the run", "[zero_run]") {
  ZeroRunDetector d;
  std::vector<float> block(100 * 2, 0.0f);
  d.update(block.data(), 100, 2);
  REQUIRE(d.zeroFrames() == 100);

  block[2 * 40 + 1] = 0.0001f;  // right channel of frame 40
  d.update(block.data(), 100, 2);
  CHECK(d.zeroFrames() == 59);  // frames 41..99 are silent again

  // A nonzero sample in the last frame leaves a run of 0.
  std::vector<float> loud(10, 0.0f);
  loud[9] = -0.5f;
  d.update(loud.data(), 10, 1);
  CHECK(d.zeroFrames() == 0);

  // It starts counting again from there.
  const std::vector<float> silence(7, 0.0f);
  d.update(silence.data(), 7, 1);
  CHECK(d.zeroFrames() == 7);
}

TEST_CASE("a frame is silent only if every channel is exactly zero", "[zero_run]") {
  ZeroRunDetector d;
  const float left_only[4] = {0.0f, 0.0f, 0.2f, 0.0f};  // frame 1 has signal in channel 0
  d.update(left_only, 2, 2);
  CHECK(d.zeroFrames() == 0);
}

TEST_CASE("negative zero is zero and tiny or odd values are not", "[zero_run]") {
  ZeroRunDetector d;
  const float negZero[3] = {-0.0f, 0.0f, -0.0f};
  d.update(negZero, 3, 1);
  CHECK(d.zeroFrames() == 3);

  const float tiny[1] = {std::numeric_limits<float>::denorm_min()};
  d.update(tiny, 1, 1);
  CHECK(d.zeroFrames() == 0);

  d.update(negZero, 3, 1);
  const float nan[1] = {std::numeric_limits<float>::quiet_NaN()};
  d.update(nan, 1, 1);
  CHECK(d.zeroFrames() == 0);
}

TEST_CASE("source views of any layout are handled the same way", "[zero_run]") {
  const std::vector<float> l = {0.0f, 0.0f, 0.1f, 0.0f, 0.0f};
  const std::vector<float> r = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
  const float* planes[2] = {l.data(), r.data()};
  std::vector<float> inter(l.size() * 2);
  for (std::size_t i = 0; i < l.size(); ++i) {
    inter[2 * i] = l[i];
    inter[2 * i + 1] = r[i];
  }

  ZeroRunDetector a, b;
  a.update(SourceView::planar(planes, 2), l.size());
  b.update(SourceView::interleaved(inter.data(), 2), l.size());
  CHECK(a.zeroFrames() == 2);
  CHECK(b.zeroFrames() == 2);

  // A source with no channels is not evidence of anything (the tap is simply not there), so it
  // neither extends nor resets the run.
  ZeroRunDetector none;
  none.update(SourceView{}, 10);
  CHECK(none.zeroFrames() == 0);
  b.update(SourceView{}, 10);
  CHECK(b.zeroFrames() == 2);
  b.update(nullptr, 10, 2);
  b.update(inter.data(), 10, 0);
  CHECK(b.zeroFrames() == 2);
}

TEST_CASE("reset clears the run", "[zero_run]") {
  ZeroRunDetector d;
  const std::vector<float> silence(10, 0.0f);
  d.update(silence.data(), 10, 1);
  d.reset();
  CHECK(d.zeroFrames() == 0);
}

TEST_CASE("the run length can be read while the audio thread updates it", "[zero_run][threads]") {
  ZeroRunDetector d;
  std::atomic<bool> done{false};
  std::atomic<std::uint64_t> maxSeen{0};

  std::thread reader([&] {
    while (!done.load(std::memory_order_acquire)) {
      const std::uint64_t n = d.zeroFrames();
      std::uint64_t seen = maxSeen.load(std::memory_order_relaxed);
      while (n > seen && !maxSeen.compare_exchange_weak(seen, n, std::memory_order_relaxed)) {
      }
    }
  });

  const std::vector<float> silence(128, 0.0f);
  for (int i = 0; i < 20000; ++i) d.update(silence.data(), 128, 1);
  done.store(true, std::memory_order_release);
  reader.join();

  CHECK(d.zeroFrames() == 20000u * 128u);
  CHECK(maxSeen.load() <= 20000u * 128u);
}
