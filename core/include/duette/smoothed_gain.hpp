#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace duette {

/// A gain that glides to each new value along a straight line, so changing the gain or the mute
/// state never clicks.
///
/// The ramp always takes exactly `rampFrames()` samples (5 ms by default) no matter how far the
/// gain has to move, and the last sample of a ramp is exactly the target. Every sample in between
/// lies between the starting value and the target. Muting is a ramp to 0; unmuting is a ramp
/// back to the remembered gain.
///
/// Not thread-safe: use it from one thread (the audio thread). To control it from elsewhere,
/// publish the wanted value in an atomic and call `setGain`/`setMuted` once per block. Setting
/// the value it already has is a no-op, so that does not restart a ramp.
class SmoothedGain {
 public:
  static constexpr float kDefaultRampSeconds = 0.005f;
  /// Longest ramp that is accepted; keeps the step arithmetic exact in a float.
  static constexpr std::size_t kMaxRampFrames = std::size_t{1} << 24;

  explicit SmoothedGain(float sampleRate = 48000.0f, float initialGain = 1.0f,
                        float rampSeconds = kDefaultRampSeconds) noexcept {
    // Clamp before converting: a NaN, infinite or enormous product is not a valid size_t.
    const double frames = std::round(static_cast<double>(sampleRate) * static_cast<double>(rampSeconds));
    if (!(frames >= 1.0)) {
      length_ = 1;
    } else if (frames >= static_cast<double>(kMaxRampFrames)) {
      length_ = kMaxRampFrames;
    } else {
      length_ = static_cast<std::size_t>(frames);
    }
    invLength_ = 1.0f / static_cast<float>(length_);
    gain_ = sanitize(initialGain, 0.0f);
    current_ = start_ = dest_ = gain_;
    position_ = length_;  // settled
  }

  /// Number of samples every ramp lasts.
  std::size_t rampFrames() const noexcept { return length_; }

  /// Sets the gain to ramp to. NaN and infinity are ignored; negative values count as 0.
  void setGain(float gain) noexcept {
    if (!std::isfinite(gain)) return;
    gain_ = gain > 0.0f ? gain : 0.0f;
    retarget();
  }

  void setMuted(bool muted) noexcept {
    muted_ = muted;
    retarget();
  }

  float gain() const noexcept { return gain_; }
  bool muted() const noexcept { return muted_; }

  /// The value the gain is heading for: 0 while muted, otherwise `gain()`.
  float target() const noexcept { return dest_; }

  /// The gain applied to the most recent sample.
  float current() const noexcept { return current_; }

  bool ramping() const noexcept { return position_ < length_; }

  /// Advances one sample and returns the gain to apply to it.
  float next() noexcept {
    if (position_ >= length_) return current_;
    ++position_;
    if (position_ == length_) {
      current_ = dest_;  // land exactly on the target
    } else {
      const float v = start_ + delta_ * (static_cast<float>(position_) * invLength_);
      current_ = delta_ > 0.0f ? std::min(v, dest_) : std::max(v, dest_);
    }
    return current_;
  }

 private:
  static float sanitize(float v, float fallback) noexcept {
    return std::isfinite(v) ? (v > 0.0f ? v : 0.0f) : fallback;
  }

  void retarget() noexcept {
    const float wanted = muted_ ? 0.0f : gain_;
    if (wanted == dest_) return;
    dest_ = wanted;
    start_ = current_;
    delta_ = dest_ - start_;
    position_ = delta_ == 0.0f ? length_ : 0;
  }

  std::size_t length_ = 1;
  float invLength_ = 1.0f;
  std::size_t position_ = 1;  // samples into the current ramp; == length_ when settled
  float gain_ = 1.0f;         // the unmuted gain
  float start_ = 1.0f;
  float dest_ = 1.0f;
  float delta_ = 0.0f;
  float current_ = 1.0f;
  bool muted_ = false;
};

}  // namespace duette
