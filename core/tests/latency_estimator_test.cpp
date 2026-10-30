#include <duette/latency_estimator.hpp>

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

using duette::LatencyEstimator;
using duette::LatencyResult;

namespace {

constexpr double kRate = 48000.0;
constexpr std::size_t kChirpFrames = 2400;  // 50 ms

// Small portable white-noise source, so every platform sees the same noise.
class Noise {
 public:
  explicit Noise(std::uint32_t seed) : state_(seed) {}
  float next() {  // uniform in [-1, 1)
    state_ = state_ * 1664525u + 1013904223u;
    return static_cast<float>(state_ >> 8) / 8388608.0f - 1.0f;
  }

 private:
  std::uint32_t state_;
};

std::vector<float> chirp() { return LatencyEstimator::makeChirp(kRate, 200.0, 20000.0, kChirpFrames, 0.5f); }

// The reference chirp after `delay` frames, scaled, with white noise of the given amplitude.
std::vector<float> record(const std::vector<float>& ref, std::size_t delay, float gain, float noiseAmplitude,
                          std::uint32_t seed, std::size_t tail = 2400) {
  std::vector<float> rec(delay + ref.size() + tail, 0.0f);
  for (std::size_t i = 0; i < ref.size(); ++i) rec[delay + i] = gain * ref[i];
  Noise noise(seed);
  for (float& s : rec) s += noiseAmplitude * noise.next();
  return rec;
}

}  // namespace

TEST_CASE("the chirp is bounded, tapered and repeatable", "[latency]") {
  const auto a = chirp();
  REQUIRE(a.size() == kChirpFrames);
  CHECK(a == chirp());
  float peak = 0.0f;
  for (float s : a) peak = std::max(peak, std::fabs(s));
  CHECK(peak <= 0.5f);
  CHECK(peak > 0.45f);
  CHECK(std::fabs(a.front()) < 0.01f);  // fades in and out, so the edges do not click
  CHECK(std::fabs(a.back()) < 0.01f);
  CHECK(LatencyEstimator::makeChirp(kRate, 200.0, 20000.0, 0).empty());
}

TEST_CASE("an injected delay is recovered exactly, with noise", "[latency]") {
  const auto ref = chirp();
  for (std::size_t delay : {0u, 37u, 480u, 4800u}) {
    // Noise at 0.2 against a 0.5 chirp: roughly 10 dB signal-to-noise over the chirp.
    const auto rec = record(ref, delay, 1.0f, 0.2f, 12345u + static_cast<std::uint32_t>(delay));
    const LatencyResult r = LatencyEstimator::estimate(ref, rec, 6000);
    INFO("delay " << delay);
    CHECK(r.lagFrames == delay);
    CHECK(r.confidence > 0.7);
    CHECK(r.confidence <= 1.0);
  }
}

TEST_CASE("the estimate does not depend on the recording level", "[latency]") {
  const auto ref = chirp();
  const auto loud = record(ref, 480, 1.0f, 0.0f, 1u);
  const auto quiet = record(ref, 480, 0.001f, 0.0f, 1u);
  const auto a = LatencyEstimator::estimate(ref, loud, 1000);
  const auto b = LatencyEstimator::estimate(ref, quiet, 1000);
  CHECK(a.lagFrames == 480);
  CHECK(b.lagFrames == 480);
  CHECK(a.confidence > 0.99);
  CHECK(b.confidence > 0.99);
}

TEST_CASE("noise alone has low confidence", "[latency]") {
  const auto ref = chirp();
  const std::vector<float> silenceWithNoise = record(ref, 0, 0.0f, 0.2f, 777u, 6000);
  const LatencyResult r = LatencyEstimator::estimate(ref, silenceWithNoise, 6000);
  CHECK(r.confidence < 0.2);

  // The same noise with a real chirp in it is far above that.
  const auto real = record(ref, 1000, 1.0f, 0.2f, 777u, 6000);
  CHECK(LatencyEstimator::estimate(ref, real, 6000).confidence > 3.0 * r.confidence);
}

TEST_CASE("an unrelated tone has low confidence", "[latency]") {
  const auto ref = chirp();
  std::vector<float> rec(10000);
  for (std::size_t i = 0; i < rec.size(); ++i) {
    rec[i] = 0.5f * static_cast<float>(std::sin(2.0 * 3.14159265358979 * 1000.0 * static_cast<double>(i) / kRate));
  }
  CHECK(LatencyEstimator::estimate(ref, rec, 6000).confidence < 0.3);
}

TEST_CASE("silence has zero confidence", "[latency]") {
  const auto ref = chirp();
  const std::vector<float> silence(8000, 0.0f);
  const LatencyResult r = LatencyEstimator::estimate(ref, silence, 4000);
  CHECK(r.confidence == 0.0);
  CHECK(r.lagFrames == 0);
}

TEST_CASE("only lags up to the limit are searched", "[latency]") {
  const auto ref = chirp();
  const auto rec = record(ref, 4800, 1.0f, 0.05f, 9u);
  const auto limited = LatencyEstimator::estimate(ref, rec, 1000);
  CHECK(limited.confidence < 0.2);  // the real lag is outside the search window
  const auto full = LatencyEstimator::estimate(ref, rec, 4800);
  CHECK(full.lagFrames == 4800);
  CHECK(full.confidence > 0.9);
}

TEST_CASE("a recording too short to hold the reference gives zero confidence", "[latency]") {
  const auto ref = chirp();
  const std::vector<float> shortRec(ref.begin(), ref.begin() + 100);
  const auto r = LatencyEstimator::estimate(ref, shortRec, 100);
  CHECK(r.confidence == 0.0);
}

TEST_CASE("empty inputs give zero confidence", "[latency]") {
  const std::vector<float> none;
  const auto ref = chirp();
  CHECK(LatencyEstimator::estimate(none, ref, 100).confidence == 0.0);
  CHECK(LatencyEstimator::estimate(ref, none, 100).confidence == 0.0);
  CHECK(LatencyEstimator::estimate(nullptr, 0, nullptr, 0, 0).confidence == 0.0);
}

TEST_CASE("the search window is clamped to what the recording can hold", "[latency]") {
  const auto ref = chirp();
  const auto rec = record(ref, 100, 1.0f, 0.0f, 3u, 0);  // chirp runs to the very last frame
  const auto r = LatencyEstimator::estimate(ref, rec, 1000000);
  CHECK(r.lagFrames == 100);
  CHECK(r.confidence > 0.99);
}
