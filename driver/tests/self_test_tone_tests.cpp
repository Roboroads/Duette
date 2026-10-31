// Tests for the self-test tone: a sine that is a pure function of sample time, switched on and
// off with a click-free fade. No Apple headers.
#include "SelfTestTone.hpp"

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

using duette::driver::SelfTestTone;
using duette::driver::ToneSwitch;
using duette::driver::toneSample;

namespace {

constexpr std::uint32_t kRate = 48000;
constexpr std::uint32_t kRamp = 240;  // 5 ms
const float kAmp = static_cast<float>(std::pow(10.0, -12.0 / 20.0));

std::size_t risingCrossings(std::int64_t start, std::size_t frames, std::uint32_t hz) {
  std::size_t n = 0;
  float previous = toneSample(start - 1, kRate, hz, kAmp);
  for (std::size_t i = 0; i < frames; ++i) {
    const float x = toneSample(start + static_cast<std::int64_t>(i), kRate, hz, kAmp);
    if (previous <= 0.0f && x > 0.0f) ++n;
    previous = x;
  }
  return n;
}

}  // namespace

TEST_CASE("the tone is a function of sample time alone") {
  for (std::int64_t t : {std::int64_t{0}, std::int64_t{1}, std::int64_t{1199}, std::int64_t{123456789}}) {
    REQUIRE(toneSample(t, kRate, 440, kAmp) == toneSample(t, kRate, 440, kAmp));
    // 440 Hz at 48 kHz repeats exactly every 1200 frames (11 cycles).
    REQUIRE(toneSample(t, kRate, 440, kAmp) == toneSample(t + 1200, kRate, 440, kAmp));
  }
  CHECK(toneSample(0, kRate, 440, kAmp) == 0.0f);
  // Negative times continue the same wave.
  CHECK(toneSample(-1, kRate, 440, kAmp) == toneSample(1199, kRate, 440, kAmp));
}

TEST_CASE("the tone has the right frequency and level") {
  CHECK(risingCrossings(0, kRate, 440) == 440);
  CHECK(risingCrossings(987654321, kRate, 440) == 440);  // after hours of uptime too
  CHECK(risingCrossings(0, kRate, 1000) == 1000);
  float peak = 0.0f;
  for (std::int64_t t = 0; t < 4800; ++t) peak = std::max(peak, std::fabs(toneSample(t, kRate, 440, kAmp)));
  CHECK(peak == Catch::Approx(kAmp).epsilon(1e-3));
  CHECK(peak <= kAmp);
}

TEST_CASE("readers of the same block get the same samples, however many there are") {
  SelfTestTone tone(kRate, 440, kAmp, kRamp);
  tone.set(true, 0);
  std::vector<float> a(512 * 2), b(512 * 2), c(512 * 2);
  auto silence = [](float* out, std::size_t frames) { std::fill(out, out + frames * 2, 0.0f); };
  std::thread ta([&] { tone.render(48000, a.data(), 512, 2, silence); });
  std::thread tb([&] { tone.render(48000, b.data(), 512, 2, silence); });
  ta.join();
  tb.join();
  tone.render(48000, c.data(), 512, 2, silence);  // and once more, later
  CHECK(a == b);
  CHECK(a == c);
}

TEST_CASE("the switch starts off and fades in over exactly the ramp") {
  ToneSwitch s(kRamp);
  CHECK_FALSE(s.on());
  CHECK(s.gainAt(0) == 0.0f);
  CHECK(s.gainAt(1'000'000) == 0.0f);

  REQUIRE(s.set(true, 1000));
  CHECK(s.on());
  CHECK(s.gainAt(999) == 0.0f);                                 // before the switch
  CHECK(s.gainAt(1000) == Catch::Approx(1.0f / kRamp));         // first ramp sample
  CHECK(s.gainAt(1000 + kRamp - 1) == 1.0f);                    // the ramp lands on 1
  CHECK(s.gainAt(5000) == 1.0f);
  float previous = 0.0f;
  for (std::int64_t t = 990; t < 1300; ++t) {
    const float g = s.gainAt(t);
    REQUIRE(g >= previous);
    REQUIRE(g - previous <= 1.0f / kRamp + 1e-6f);  // no jump bigger than one ramp step
    previous = g;
  }

  CHECK_FALSE(s.set(true, 2000));  // already on: nothing changes
  CHECK(s.gainAt(1000) == Catch::Approx(1.0f / kRamp));
}

TEST_CASE("switching off fades out the same way") {
  ToneSwitch s(kRamp);
  s.set(true, 0);
  REQUIRE(s.set(false, 10000));
  CHECK_FALSE(s.on());
  CHECK(s.gainAt(9999) == 1.0f);
  CHECK(s.gainAt(10000 + kRamp - 1) == 0.0f);
  CHECK(s.gainAt(20000) == 0.0f);
}

TEST_CASE("switching again in the middle of a fade continues from where the fade was") {
  ToneSwitch s(kRamp);
  s.set(true, 1000);
  const float before = s.gainAt(1099);
  REQUIRE(s.set(false, 1100));
  const float after = s.gainAt(1100);
  CHECK(before == Catch::Approx(100.0f / kRamp).margin(1e-4));
  CHECK(std::fabs(after - before) <= 1.0f / kRamp + 1e-4f);  // no click
  CHECK(s.gainAt(1100 + kRamp - 1) == 0.0f);
}

TEST_CASE("render passes the sink audio through while off and replaces it while on") {
  SelfTestTone tone(kRate, 440, kAmp, kRamp);
  int sourceCalls = 0;
  auto source = [&](float* out, std::size_t frames) {
    ++sourceCalls;
    std::fill(out, out + frames * 2, 0.75f);
  };
  std::vector<float> out(256 * 2);

  tone.render(0, out.data(), 256, 2, source);
  CHECK(sourceCalls == 1);
  CHECK(std::all_of(out.begin(), out.end(), [](float x) { return x == 0.75f; }));

  tone.set(true, 1000);
  tone.render(2000, out.data(), 256, 2, source);  // well after the fade: tone only
  CHECK(sourceCalls == 1);
  for (std::size_t i = 0; i < 256; ++i) {
    const float want = toneSample(2000 + static_cast<std::int64_t>(i), kRate, 440, kAmp);
    REQUIRE(out[i * 2] == want);
    REQUIRE(out[i * 2 + 1] == want);
  }

  // A block across the switch blends the two along the fade.
  tone.render(900, out.data(), 256, 2, source);
  CHECK(sourceCalls == 2);
  CHECK(out[0] == 0.75f);  // t = 900, before the switch
  const std::size_t mid = 1000 - 900 + kRamp / 2 - 1;  // halfway through the fade
  const auto t = static_cast<std::int64_t>(900 + mid);
  const float g = 0.5f;
  CHECK(out[mid * 2] == Catch::Approx(0.75f * (1.0f - g) + toneSample(t, kRate, 440, kAmp) * g).margin(1e-5));
}
