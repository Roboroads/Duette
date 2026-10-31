// Tests for the clock the plug-in's devices share. They need no Apple headers: the host clock is
// a stub, so they build and run on Linux as well as on macOS.
#include "SharedClock.hpp"

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cstdint>

using duette::driver::ClockConfig;
using duette::driver::HostTimebase;
using duette::driver::SharedClock;
using duette::driver::ZeroTimeStamp;

namespace {

// The stubbed host clock. Tests move it by hand.
std::uint64_t gHostNow = 0;
std::uint64_t stubHostNow() noexcept { return gHostNow; }

// mach_timebase_info on Apple Silicon: 125/3 ns per tick, so 24 MHz ticks.
constexpr HostTimebase kAppleSilicon{125, 3};
// Intel Macs: one tick per nanosecond.
constexpr HostTimebase kIntel{1, 1};

constexpr std::uint64_t kAnchor = 1'000'000'000;

ClockConfig config48k() {
  ClockConfig c;
  c.sampleRate = 48000.0;
  c.periodFrames = 16384;
  return c;
}

bool same(const ZeroTimeStamp& a, const ZeroTimeStamp& b) {
  return a.sampleTime == b.sampleTime && a.hostTime == b.hostTime && a.seed == b.seed;
}

}  // namespace

TEST_CASE("both devices report the same zero timestamp for the same host time") {
  gHostNow = kAnchor;
  // The plug-in builds one clock when it loads and hands it to "Duette" and "Duette Sink".
  const SharedClock clock(&stubHostNow, kAppleSilicon, stubHostNow(), config48k());
  const SharedClock& duette = clock;
  const SharedClock& sink = clock;

  for (std::uint64_t step = 0; step < 5000; ++step) {
    gHostNow = kAnchor + step * 7919;  // a prime stride, so it lands on and between boundaries
    const ZeroTimeStamp a = duette.now();
    const ZeroTimeStamp b = sink.now();
    REQUIRE(same(a, b));
  }
}

TEST_CASE("two clocks built from the same anchor and settings agree") {
  // A device rebuilt later (for example after a sample-rate change) must stay on the timeline.
  gHostNow = kAnchor + 123'456'789;
  const SharedClock first(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  const SharedClock second(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  for (std::uint64_t t = kAnchor; t < kAnchor + 200'000'000; t += 999'983) {
    REQUIRE(same(first.at(t), second.at(t)));
  }
}

TEST_CASE("the timeline starts at sample 0 at the anchor") {
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  const ZeroTimeStamp z = clock.at(kAnchor);
  CHECK(z.sampleTime == 0.0);
  CHECK(z.hostTime == kAnchor);
  CHECK(z.seed == 1);
}

TEST_CASE("host times before the anchor clamp to the first timestamp") {
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  const ZeroTimeStamp z = clock.at(kAnchor - 1);
  CHECK(z.sampleTime == 0.0);
  CHECK(z.hostTime == kAnchor);
}

TEST_CASE("48 kHz on Apple Silicon is exactly 500 host ticks per frame") {
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  CHECK(clock.hostTicksPerFrame() == 500.0);

  const std::uint64_t ticksPerPeriod = 500u * 16384u;
  CHECK(clock.at(kAnchor + ticksPerPeriod - 1).sampleTime == 0.0);

  const ZeroTimeStamp one = clock.at(kAnchor + ticksPerPeriod);
  CHECK(one.sampleTime == 16384.0);
  CHECK(one.hostTime == kAnchor + ticksPerPeriod);

  const ZeroTimeStamp many = clock.at(kAnchor + 1000 * ticksPerPeriod + 17);
  CHECK(many.sampleTime == 1000.0 * 16384.0);
  CHECK(many.hostTime == kAnchor + 1000 * ticksPerPeriod);
}

TEST_CASE("the zero timestamp is the latest period boundary at or before now") {
  const SharedClock clock(&stubHostNow, kIntel, kAnchor, config48k());
  const double ticksPerPeriod = clock.hostTicksPerFrame() * 16384.0;
  for (std::uint64_t t = kAnchor; t < kAnchor + 50 * static_cast<std::uint64_t>(ticksPerPeriod);
       t += 1'234'567) {
    const ZeroTimeStamp z = clock.at(t);
    REQUIRE(z.hostTime <= t);
    REQUIRE(static_cast<double>(t - z.hostTime) < ticksPerPeriod + 1.0);
    // Sample times are whole periods.
    const double periods = z.sampleTime / 16384.0;
    REQUIRE(periods == static_cast<double>(static_cast<std::uint64_t>(periods)));
  }
}

TEST_CASE("successive timestamps are one period apart in samples and in host time") {
  const SharedClock clock(&stubHostNow, kIntel, kAnchor, config48k());
  const double ticksPerPeriod = clock.hostTicksPerFrame() * 16384.0;
  ZeroTimeStamp previous = clock.at(kAnchor);
  std::uint64_t t = kAnchor;
  int boundaries = 0;
  while (boundaries < 100) {
    t += 100'000;  // well under a period (about 341 ms of nanoseconds)
    const ZeroTimeStamp z = clock.at(t);
    REQUIRE(z.sampleTime >= previous.sampleTime);  // never goes back
    if (z.sampleTime != previous.sampleTime) {
      REQUIRE(z.sampleTime - previous.sampleTime == 16384.0);
      const double hostStep = static_cast<double>(z.hostTime - previous.hostTime);
      REQUIRE(hostStep == Catch::Approx(ticksPerPeriod).margin(1.0));
      ++boundaries;
    }
    previous = z;
  }
}

TEST_CASE("44.1 kHz uses the same anchor with its own period length") {
  ClockConfig c = config48k();
  c.sampleRate = 44100.0;
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, c);
  CHECK(clock.hostTicksPerFrame() == Catch::Approx(24'000'000.0 / 44100.0));
  // One second of host time holds 44100 frames: two whole periods of 16384.
  CHECK(clock.at(kAnchor + 24'000'000).sampleTime == 2.0 * 16384.0);
}

TEST_CASE("a clock running 200 ppm fast gains 9.6 frames per second at 48 kHz") {
  ClockConfig fast = config48k();
  fast.ppm = 200.0;
  const SharedClock nominal(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  const SharedClock drifting(&stubHostNow, kAppleSilicon, kAnchor, fast);

  CHECK(drifting.hostTicksPerFrame() == Catch::Approx(500.0 / 1.0002));

  // Over one hour, the fast clock reaches each period boundary earlier, so it is ahead by
  // 3600 * 9.6 = 34560 frames, give or take the one period the timestamps are quantized to.
  const std::uint64_t oneHour = 3600ull * 24'000'000ull;
  const double ahead = drifting.at(kAnchor + oneHour).sampleTime - nominal.at(kAnchor + oneHour).sampleTime;
  CHECK(ahead >= 34560.0 - 16384.0);
  CHECK(ahead <= 34560.0 + 16384.0);
}

TEST_CASE("the clock stays exact after days of uptime") {
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  const std::uint64_t ticksPerPeriod = 500u * 16384u;
  const std::uint64_t n = 30ull * 24 * 3600 * 48000 / 16384;  // about 30 days of periods
  const ZeroTimeStamp z = clock.at(kAnchor + n * ticksPerPeriod + ticksPerPeriod / 2);
  CHECK(z.sampleTime == static_cast<double>(n) * 16384.0);
  CHECK(z.hostTime == kAnchor + n * ticksPerPeriod);
}

TEST_CASE("invalid settings fall back to safe values") {
  ClockConfig bad;
  bad.sampleRate = 0.0;
  bad.periodFrames = 0;
  const SharedClock clock(&stubHostNow, HostTimebase{0, 0}, kAnchor, bad);
  CHECK(clock.sampleRate() == 48000.0);
  CHECK(clock.periodFrames() == 16384u);
  CHECK(clock.hostTicksPerFrame() > 0.0);
  CHECK(clock.at(kAnchor + 10'000'000'000ull).sampleTime >= 0.0);
}

TEST_CASE("sampleTimeAt gives the exact sample time between timestamps") {
  const SharedClock clock(&stubHostNow, kAppleSilicon, kAnchor, config48k());
  CHECK(clock.sampleTimeAt(kAnchor) == 0.0);
  CHECK(clock.sampleTimeAt(kAnchor - 10) == 0.0);
  CHECK(clock.sampleTimeAt(kAnchor + 500u * 12345u) == 12345.0);
  CHECK(clock.sampleTimeAt(kAnchor + 500u * 12345u + 250u) == 12345.5);
  // It agrees with the zero timestamps at every boundary.
  const std::uint64_t boundary = kAnchor + 500u * 16384u * 7u;
  CHECK(clock.sampleTimeAt(boundary) == clock.at(boundary).sampleTime);
}
