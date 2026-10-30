#include <duette/tone.hpp>

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <limits>
#include <vector>

using duette::ToneGenerator;

namespace {

std::vector<float> generate(ToneGenerator& t, std::size_t frames) {
  std::vector<float> v(frames);
  t.fill(v.data(), frames);
  return v;
}

// Counts rising zero crossings (negative or zero sample followed by a positive one).
std::size_t risingCrossings(const std::vector<float>& x) {
  std::size_t n = 0;
  for (std::size_t i = 1; i < x.size(); ++i) {
    if (x[i - 1] <= 0.0f && x[i] > 0.0f) ++n;
  }
  return n;
}

std::size_t allCrossings(const std::vector<float>& x) {
  std::size_t n = 0;
  for (std::size_t i = 1; i < x.size(); ++i) {
    if ((x[i - 1] < 0.0f) != (x[i] < 0.0f)) ++n;
  }
  return n;
}

}  // namespace

TEST_CASE("the frequency is right by zero-crossing count", "[tone]") {
  // One second of audio holds exactly `hz` cycles.
  for (float hz : {100.0f, 440.0f, 997.0f, 1000.0f, 5000.0f, 12000.0f}) {
    ToneGenerator t(48000.0f, hz, 0.5f);
    const auto x = generate(t, 48000);
    INFO(hz << " Hz");
    CHECK(risingCrossings(x) == static_cast<std::size_t>(hz));
    // Two sign changes per cycle; the count may differ by one at the ends.
    const auto all = static_cast<std::ptrdiff_t>(allCrossings(x));
    CHECK(std::abs(all - static_cast<std::ptrdiff_t>(2.0f * hz)) <= 1);
  }
}

TEST_CASE("the frequency scales with the sample rate", "[tone]") {
  ToneGenerator t(44100.0f, 1000.0f, 0.5f);
  const auto x = generate(t, 44100);
  CHECK(risingCrossings(x) == 1000);
}

TEST_CASE("it starts at phase zero with the requested amplitude", "[tone]") {
  ToneGenerator t(48000.0f, 1000.0f, 0.5f);
  const auto x = generate(t, 480);
  CHECK(x[0] == 0.0f);
  CHECK(*std::max_element(x.begin(), x.end()) == Catch::Approx(0.5f).epsilon(1e-4));
  CHECK(*std::min_element(x.begin(), x.end()) == Catch::Approx(-0.5f).epsilon(1e-4));
}

TEST_CASE("phase is continuous across blocks of any size", "[tone]") {
  ToneGenerator whole(48000.0f, 997.0f, 0.5f);
  const auto expected = generate(whole, 2000);

  ToneGenerator cut(48000.0f, 997.0f, 0.5f);
  std::vector<float> got;
  for (std::size_t n : {1u, 7u, 64u, 128u, 3u, 500u, 1u, 1296u}) {
    const auto block = generate(cut, n);
    got.insert(got.end(), block.begin(), block.end());
  }
  REQUIRE(got.size() == expected.size());
  CHECK(got == expected);  // bit-identical: no phase reset or jump at block edges
}

TEST_CASE("phase stays continuous when the frequency changes", "[tone]") {
  ToneGenerator t(48000.0f, 440.0f, 0.5f);
  auto x = generate(t, 1000);
  t.setFrequency(880.0f);
  const auto y = generate(t, 1000);
  x.insert(x.end(), y.begin(), y.end());

  // The steepest slope of 0.5 * sin at 880 Hz is 0.5 * 2*pi*880/48000 per sample; a phase jump
  // would exceed it.
  const float maxStep = 0.5f * 2.0f * 3.14159265f * 880.0f / 48000.0f * 1.001f;
  for (std::size_t i = 1; i < x.size(); ++i) {
    REQUIRE(std::fabs(x[i] - x[i - 1]) <= maxStep);
  }
}

TEST_CASE("the tone stays accurate over a long run", "[tone]") {
  ToneGenerator t(48000.0f, 1000.0f, 1.0f);
  std::vector<float> block(4800);
  for (int i = 0; i < 2000; ++i) t.fill(block.data(), block.size());  // 3.3 minutes
  t.fill(block.data(), block.size());
  // 1000 Hz at 48 kHz repeats every 48 samples, so the block must look like a fresh tone
  // shifted by a whole number of periods: sample 0 is still on phase 0.
  CHECK(std::fabs(block[0]) < 1e-4f);
  CHECK(block[12] == Catch::Approx(1.0f).margin(1e-4));
}

TEST_CASE("every channel of an interleaved frame gets the same sample", "[tone]") {
  ToneGenerator mono(48000.0f, 1000.0f, 0.5f);
  const auto m = generate(mono, 100);

  ToneGenerator stereo(48000.0f, 1000.0f, 0.5f);
  std::vector<float> s(100 * 2);
  stereo.fill(s.data(), 100, 2);
  for (std::size_t i = 0; i < 100; ++i) {
    CHECK(s[2 * i] == m[i]);
    CHECK(s[2 * i + 1] == m[i]);
  }
}

TEST_CASE("amplitude 0 is silence and a new amplitude applies", "[tone]") {
  ToneGenerator t(48000.0f, 1000.0f, 0.0f);
  for (float v : generate(t, 100)) CHECK(v == 0.0f);

  t.setAmplitude(0.25f);
  const auto x = generate(t, 480);
  CHECK(*std::max_element(x.begin(), x.end()) == Catch::Approx(0.25f).epsilon(1e-3));
}

TEST_CASE("invalid settings are handled", "[tone]") {
  ToneGenerator t(48000.0f, 1000.0f, 0.5f);
  t.setFrequency(std::numeric_limits<float>::quiet_NaN());
  CHECK(t.frequency() == 1000.0f);
  t.setFrequency(-5.0f);
  CHECK(t.frequency() == 0.0f);
  t.setFrequency(1.0e9f);
  CHECK(t.frequency() == 24000.0f);  // Nyquist
  t.setAmplitude(std::numeric_limits<float>::quiet_NaN());
  CHECK(t.amplitude() == 0.5f);
  t.setAmplitude(-1.0f);
  CHECK(t.amplitude() == 0.0f);
}

TEST_CASE("reset restarts at phase zero", "[tone]") {
  ToneGenerator t(48000.0f, 1000.0f, 0.5f);
  const auto first = generate(t, 37);
  t.reset();
  const auto again = generate(t, 37);
  CHECK(first == again);
}
