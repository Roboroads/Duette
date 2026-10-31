#pragma once

// The self-test tone of "Duette" ('dtst') and the test mic's tone. No Apple headers, so it is
// tested on Linux.
//
// Several clients can read "Duette" at once, possibly from different IO threads, and the HAL can
// ask for the same cycle more than once. So nothing here keeps per-call state: the tone is a pure
// function of sample time, and the on/off fade is a pure function of sample time and one atomic
// word that says when the switch happened.

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace duette::driver {

/// Sample of a sine at `hz` (phase 0 at sample time 0) for sample time `t`. Exact for any t:
/// the phase is computed from t mod sampleRate in integers, so the wave repeats bit for bit
/// (440 Hz at 48 kHz every 1200 frames) and never drifts over hours of uptime.
inline float toneSample(std::int64_t t, std::uint32_t sampleRate, std::uint32_t hz,
                        float amplitude) noexcept {
  if (sampleRate == 0) return 0.0f;
  const auto rate = static_cast<std::int64_t>(sampleRate);
  std::int64_t k = t % rate;
  if (k < 0) k += rate;
  k = (k * static_cast<std::int64_t>(hz)) % rate;
  constexpr double kTwoPi = 6.283185307179586476925286766559;
  return amplitude *
         static_cast<float>(std::sin(kTwoPi * static_cast<double>(k) / static_cast<double>(rate)));
}

/// On/off switch with a linear fade, readable from any number of threads.
///
/// `set` records the sample time of the switch, the gain at that moment and the new state in one
/// atomic word. The gain at sample time t follows from that alone: the old gain before the
/// switch, then a ramp of exactly `rampFrames` samples whose last sample is the target, the same
/// shape SmoothedGain makes. (SmoothedGain itself keeps its ramp position per call, which breaks
/// with more than one reader.) Switching again mid-fade starts the new ramp from where the old
/// one was, so it never clicks.
class ToneSwitch {
 public:
  struct State {
    std::int64_t start = 0;  // sample time of the last switch
    float from = 0.0f;       // gain before it
    bool on = false;         // state after it
  };

  explicit ToneSwitch(std::uint32_t rampFrames) noexcept
      : ramp_(rampFrames > 0 ? rampFrames : 1u) {}

  /// Switches to `on` at sample time `at`. Returns false when it already was in that state.
  bool set(bool on, std::int64_t at) noexcept {
    std::uint64_t old = word_.load(std::memory_order_acquire);
    for (;;) {
      const State s = unpack(old);
      if (s.on == on) return false;
      State next;
      next.start = at;
      next.from = gain(s, at, ramp_);
      next.on = on;
      if (word_.compare_exchange_weak(old, pack(next), std::memory_order_acq_rel,
                                      std::memory_order_acquire)) {
        return true;
      }
    }
  }

  bool on() const noexcept { return state().on; }
  State state() const noexcept { return unpack(word_.load(std::memory_order_acquire)); }
  std::uint32_t rampFrames() const noexcept { return ramp_; }
  float gainAt(std::int64_t t) const noexcept { return gain(state(), t, ramp_); }

  /// Gain at sample time `t` for state `s`; 0 is off, 1 is fully on.
  static float gain(const State& s, std::int64_t t, std::uint32_t rampFrames) noexcept {
    if (t < s.start) return s.from;
    const float target = s.on ? 1.0f : 0.0f;
    const std::int64_t d = t - s.start;
    if (d + 1 >= static_cast<std::int64_t>(rampFrames)) return target;
    const float progress = static_cast<float>(d + 1) / static_cast<float>(rampFrames);
    return s.from + (target - s.from) * progress;
  }

 private:
  // Bit 0: on. Bits 1..16: the gain before the switch, in 1/65535 steps. Bits 17..63: the sample
  // time of the switch (47 bits: about 93 years at 48 kHz).
  static constexpr std::uint64_t kGainSteps = 65535;
  static constexpr std::int64_t kMaxStart = (std::int64_t{1} << 47) - 1;

  static std::uint64_t pack(const State& s) noexcept {
    const std::int64_t start = s.start < 0 ? 0 : (s.start > kMaxStart ? kMaxStart : s.start);
    float from = s.from < 0.0f ? 0.0f : (s.from > 1.0f ? 1.0f : s.from);
    const auto steps = static_cast<std::uint64_t>(std::lround(static_cast<double>(from) * kGainSteps));
    return (static_cast<std::uint64_t>(start) << 17) | (steps << 1) | (s.on ? 1u : 0u);
  }

  static State unpack(std::uint64_t w) noexcept {
    State s;
    s.on = (w & 1u) != 0;
    s.from = static_cast<float>(static_cast<double>((w >> 1) & kGainSteps) / kGainSteps);
    s.start = static_cast<std::int64_t>(w >> 17);
    return s;
  }

  static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "the IO path must not take locks");

  std::uint32_t ramp_;
  std::atomic<std::uint64_t> word_{0};  // off since sample time 0
};

/// The "Duette" self-test tone: a sine faded in and out by a ToneSwitch.
class SelfTestTone {
 public:
  SelfTestTone(std::uint32_t sampleRate, std::uint32_t hz, float amplitude,
               std::uint32_t rampFrames) noexcept
      : rate_(sampleRate), hz_(hz), amplitude_(amplitude), switch_(rampFrames) {}

  /// Control thread. See ToneSwitch::set.
  bool set(bool on, std::int64_t at) noexcept { return switch_.set(on, at); }
  bool on() const noexcept { return switch_.on(); }

  /// Any IO thread. Fills `frames` interleaved frames from sample time `t`. While the tone is
  /// off, `readSource(out, frames)` provides the audio (the sink's); while it is on, the tone
  /// replaces it; during a fade the two are blended. `readSource` is not called when the tone
  /// covers the whole block.
  template <typename ReadSource>
  void render(std::int64_t t, float* out, std::size_t frames, std::size_t channels,
              ReadSource&& readSource) const noexcept {
    if (out == nullptr || frames == 0) return;
    const ToneSwitch::State s = switch_.state();
    const std::uint32_t ramp = switch_.rampFrames();
    // The gain only moves one way within a state, so the ends of the block bound it.
    const float first = ToneSwitch::gain(s, t, ramp);
    const float last = ToneSwitch::gain(s, t + static_cast<std::int64_t>(frames) - 1, ramp);
    if (first == 0.0f && last == 0.0f) {
      readSource(out, frames);
      return;
    }
    if (first == 1.0f && last == 1.0f) {
      for (std::size_t i = 0; i < frames; ++i) {
        const float x = toneSample(t + static_cast<std::int64_t>(i), rate_, hz_, amplitude_);
        for (std::size_t c = 0; c < channels; ++c) out[i * channels + c] = x;
      }
      return;
    }
    readSource(out, frames);
    for (std::size_t i = 0; i < frames; ++i) {
      const std::int64_t ti = t + static_cast<std::int64_t>(i);
      const float g = ToneSwitch::gain(s, ti, ramp);
      const float x = toneSample(ti, rate_, hz_, amplitude_) * g;
      for (std::size_t c = 0; c < channels; ++c) {
        out[i * channels + c] = out[i * channels + c] * (1.0f - g) + x;
      }
    }
  }

 private:
  std::uint32_t rate_;
  std::uint32_t hz_;
  float amplitude_;
  ToneSwitch switch_;
};

}  // namespace duette::driver
