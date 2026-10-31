#pragma once

// The clock behind every device of the plug-in. No Apple headers: the host clock comes in as a
// function, so the tests run on Linux with a stub.

#include <cmath>
#include <cstdint>

namespace duette::driver {

/// Host clock rate the way mach_timebase_info gives it: nanoseconds = ticks * numer / denom.
struct HostTimebase {
  std::uint32_t numer = 1;
  std::uint32_t denom = 1;
};

/// What a device answers to the HAL's GetZeroTimeStamp.
struct ZeroTimeStamp {
  double sampleTime = 0.0;
  std::uint64_t hostTime = 0;
  std::uint64_t seed = 1;
};

/// Rate settings of one clock.
struct ClockConfig {
  double sampleRate = 48000.0;
  /// Frames between successive zero timestamps (kAudioDevicePropertyZeroTimeStampPeriod).
  std::uint32_t periodFrames = 16384;
  /// How far the clock runs from its nominal rate, in parts per million; positive is fast.
  /// The test mic uses +200 to give drift compensation something to correct.
  double ppm = 0.0;
};

/// Reads the host clock (mach_absolute_time on macOS).
using HostTimeFn = std::uint64_t (*)() noexcept;

/// A device clock that is a pure function of host time.
///
/// The zero timestamp for host time `t` is the latest period boundary at or before `t`, counted
/// from a fixed anchor. Nothing changes when IO starts or stops, so every device built from the
/// same anchor and settings ("Duette" and "Duette Sink" share one instance) reports identical
/// sample times for the same moment, which is what lets the sink's writes line up with the
/// input's reads and lets the HAL treat the two devices as one clock domain.
///
/// Every member is const and allocation-free: safe to call from any thread, including the HAL's
/// real-time IO threads, without locking.
class SharedClock {
 public:
  static constexpr std::uint64_t kSeed = 1;

  SharedClock(HostTimeFn hostNowFn, HostTimebase timebase, std::uint64_t anchorHostTime,
              ClockConfig config) noexcept
      : hostNow_(hostNowFn), anchor_(anchorHostTime) {
    sampleRate_ = (config.sampleRate > 0.0 && std::isfinite(config.sampleRate)) ? config.sampleRate
                                                                                 : 48000.0;
    period_ = config.periodFrames > 0 ? config.periodFrames : 16384u;
    const double numer = timebase.numer > 0 ? static_cast<double>(timebase.numer) : 1.0;
    const double denom = timebase.denom > 0 ? static_cast<double>(timebase.denom) : 1.0;
    const double ticksPerSecond = 1e9 * denom / numer;
    double ppm = std::isfinite(config.ppm) ? config.ppm : 0.0;
    if (ppm <= -1e6) ppm = 0.0;
    const double framesPerSecond = sampleRate_ * (1.0 + ppm * 1e-6);
    ticksPerFrame_ = ticksPerSecond / framesPerSecond;
    ticksPerPeriod_ = ticksPerFrame_ * static_cast<double>(period_);
  }

  /// Zero timestamp at host time `hostTime`.
  ZeroTimeStamp at(std::uint64_t hostTime) const noexcept {
    ZeroTimeStamp z;
    z.seed = kSeed;
    if (hostTime <= anchor_) {
      z.hostTime = anchor_;
      return z;
    }
    const double elapsed = static_cast<double>(hostTime - anchor_);
    auto periods = static_cast<std::uint64_t>(elapsed / ticksPerPeriod_);
    std::uint64_t boundary = boundaryHostTime(periods);
    // Rounding can put the boundary a tick past `hostTime`; the timestamp must not be in the
    // future.
    while (periods > 0 && boundary > hostTime) {
      --periods;
      boundary = boundaryHostTime(periods);
    }
    z.sampleTime = static_cast<double>(periods) * static_cast<double>(period_);
    z.hostTime = boundary;
    return z;
  }

  /// Zero timestamp right now.
  ZeroTimeStamp now() const noexcept { return at(hostNow_()); }

  std::uint64_t hostNow() const noexcept { return hostNow_(); }
  std::uint64_t anchorHostTime() const noexcept { return anchor_; }
  double sampleRate() const noexcept { return sampleRate_; }
  std::uint32_t periodFrames() const noexcept { return period_; }
  double hostTicksPerFrame() const noexcept { return ticksPerFrame_; }

 private:
  std::uint64_t boundaryHostTime(std::uint64_t periods) const noexcept {
    return anchor_ + static_cast<std::uint64_t>(
                         std::floor(static_cast<double>(periods) * ticksPerPeriod_ + 0.5));
  }

  HostTimeFn hostNow_;
  std::uint64_t anchor_;
  double sampleRate_ = 48000.0;
  std::uint32_t period_ = 16384;
  double ticksPerFrame_ = 1.0;
  double ticksPerPeriod_ = 1.0;
};

}  // namespace duette::driver
