#include <duette/smoothed_gain.hpp>

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstddef>
#include <limits>
#include <vector>

using duette::SmoothedGain;

namespace {

std::vector<float> run(SmoothedGain& g, std::size_t n) {
  std::vector<float> v(n);
  for (float& x : v) x = g.next();
  return v;
}

bool monotonic(const std::vector<float>& v, bool rising) {
  for (std::size_t i = 1; i < v.size(); ++i) {
    if (rising ? v[i] < v[i - 1] : v[i] > v[i - 1]) return false;
  }
  return true;
}

}  // namespace

TEST_CASE("the ramp is 5 ms long", "[gain]") {
  CHECK(SmoothedGain(48000.0f).rampFrames() == 240);
  CHECK(SmoothedGain(96000.0f).rampFrames() == 480);
  CHECK(SmoothedGain(8000.0f).rampFrames() == 40);
  CHECK(SmoothedGain(1.0f).rampFrames() >= 1);  // never zero, even for silly rates
}

TEST_CASE("the initial gain applies immediately", "[gain]") {
  SmoothedGain g(48000.0f, 0.7f);
  CHECK_FALSE(g.ramping());
  CHECK(g.next() == 0.7f);
  CHECK(g.next() == 0.7f);
}

TEST_CASE("a new gain is reached in exactly the ramp length", "[gain]") {
  SmoothedGain g(48000.0f, 0.0f);
  g.setGain(1.0f);
  CHECK(g.ramping());

  const auto v = run(g, 239);
  CHECK(v.back() < 1.0f);
  CHECK(g.ramping());
  CHECK(g.next() == 1.0f);  // the 240th sample is exactly the target
  CHECK_FALSE(g.ramping());
  CHECK(g.next() == 1.0f);  // and it stays there
}

TEST_CASE("the ramp is linear and starts moving on the first sample", "[gain]") {
  SmoothedGain g(48000.0f, 0.0f);
  g.setGain(1.0f);
  const auto v = run(g, 240);
  for (std::size_t i = 0; i < v.size(); ++i) {
    CHECK(v[i] == Catch::Approx(static_cast<float>(i + 1) / 240.0f).margin(1e-6));
  }
}

TEST_CASE("a ramp never overshoots its endpoints", "[gain]") {
  const float cases[][2] = {{0.0f, 1.0f}, {1.0f, 0.0f}, {1.0f, 2.0f}, {2.0f, 0.3f},
                            {1.0f, 1.0001f}, {1.0001f, 1.0f}, {0.3f, 0.30000004f}};
  for (const auto& c : cases) {
    SmoothedGain g(48000.0f, c[0]);
    g.setGain(c[1]);
    const auto v = run(g, 300);
    const float lo = std::fmin(c[0], c[1]);
    const float hi = std::fmax(c[0], c[1]);
    INFO("from " << c[0] << " to " << c[1]);
    for (float x : v) {
      CHECK(x >= lo);
      CHECK(x <= hi);
    }
    CHECK(monotonic(v, c[1] > c[0]));
    CHECK(v[239] == c[1]);
    CHECK(v.back() == c[1]);
  }
}

TEST_CASE("setting the gain it already has does not restart the ramp", "[gain]") {
  SmoothedGain g(48000.0f, 0.0f);
  g.setGain(1.0f);
  run(g, 100);
  const float before = g.current();
  for (int i = 0; i < 50; ++i) g.setGain(1.0f);  // the engine does this every block
  const auto v = run(g, 140);
  CHECK(v.front() > before);
  CHECK(v.back() == 1.0f);  // still done after 240 samples in total
  CHECK_FALSE(g.ramping());
}

TEST_CASE("retargeting mid-ramp takes a full ramp from where it is", "[gain]") {
  SmoothedGain g(48000.0f, 0.0f);
  g.setGain(1.0f);
  run(g, 100);
  const float mid = g.current();
  g.setGain(0.25f);
  const auto v = run(g, 240);
  CHECK(v.front() <= mid);
  CHECK(monotonic(v, false));
  CHECK(v.back() == 0.25f);
  CHECK(v[238] > 0.25f);
}

TEST_CASE("mute ramps to zero and unmute ramps back up from zero", "[gain]") {
  SmoothedGain g(48000.0f, 1.0f);
  g.setMuted(true);
  const auto down = run(g, 240);
  CHECK(monotonic(down, false));
  CHECK(down.back() == 0.0f);
  CHECK(down.front() > 0.0f);  // it ramps; it does not click to zero

  g.setMuted(false);
  const auto up = run(g, 240);
  CHECK(up.front() > 0.0f);
  CHECK(up.front() < 0.01f);  // starts near 0
  CHECK(monotonic(up, true));
  CHECK(up[238] < 1.0f);
  CHECK(up.back() == 1.0f);
}

TEST_CASE("the gain is remembered while muted", "[gain]") {
  SmoothedGain g(48000.0f, 1.0f);
  g.setMuted(true);
  run(g, 240);
  g.setGain(0.5f);
  CHECK(g.next() == 0.0f);  // still muted, nothing moves
  CHECK_FALSE(g.ramping());
  g.setMuted(false);
  const auto up = run(g, 240);
  CHECK(up.back() == 0.5f);
}

TEST_CASE("mute while ramping up reverses from the current value", "[gain]") {
  SmoothedGain g(48000.0f, 0.0f);
  g.setGain(1.0f);
  run(g, 120);
  const float mid = g.current();
  g.setMuted(true);
  const auto v = run(g, 240);
  CHECK(v.front() <= mid);
  CHECK(monotonic(v, false));
  CHECK(v.back() == 0.0f);
}

TEST_CASE("invalid gains are handled", "[gain]") {
  SmoothedGain g(48000.0f, 0.5f);
  g.setGain(std::numeric_limits<float>::quiet_NaN());
  CHECK(g.gain() == 0.5f);
  CHECK_FALSE(g.ramping());

  g.setGain(-3.0f);  // negative gain would invert the signal: treated as 0
  CHECK(g.gain() == 0.0f);

  g.setGain(std::numeric_limits<float>::infinity());
  CHECK(g.gain() == 0.0f);  // not finite: ignored
}
