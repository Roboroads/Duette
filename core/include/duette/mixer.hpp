#pragma once

#include <cmath>
#include <cstddef>

#include "audio_view.hpp"
#include "smoothed_gain.hpp"

namespace duette {

/// Where `Mixer::process` writes its stereo result: two channels, each a start pointer plus a
/// distance in floats between consecutive frames.
struct StereoOut {
  float* left = nullptr;
  float* right = nullptr;
  std::size_t stride = 1;

  /// L R L R ... starting at `data`.
  static StereoOut interleaved(float* data) noexcept { return {data, data + 1, 2}; }
  /// Separate left and right buffers.
  static StereoOut planar(float* left, float* right) noexcept { return {left, right, 1}; }
};

/// The Duette mix: `out = clip(appGain * tap + micGain * mono(mic))` per side.
///
/// - The mic is averaged over all its channels into one mono signal that goes to both sides.
/// - A tap with one channel goes to both sides; with two or more, channels 0 and 1 are left and
///   right and the rest are ignored.
/// - A source with no channels counts as silence.
/// - Non-finite input samples (NaN, infinity) count as 0.
/// - The result is hard-clipped to [-1, 1].
/// - Gains are limited to 0..2 and glide over 5 ms; mute is a gain ramp to 0 and back. After a
///   ramp has finished, a muted or 0-gain source contributes exactly 0 (it is not even read, so
///   huge samples in it cannot matter).
///
/// Real-time safe: `process` and the setters do not allocate, lock, throw or call the system.
/// Use one `Mixer` from one thread; feed it parameters from atomics at the start of each block.
/// Input and output buffers must not overlap.
class Mixer {
 public:
  static constexpr float kMaxGain = 2.0f;  // +6 dB

  explicit Mixer(float sampleRate = 48000.0f) noexcept
      : appGain_(sampleRate, 1.0f), micGain_(sampleRate, 1.0f) {}

  /// Gains are clamped to [0, kMaxGain]. NaN and infinity are ignored.
  void setAppGain(float gain) noexcept {
    if (std::isfinite(gain)) appGain_.setGain(limit(gain));
  }
  void setMicGain(float gain) noexcept {
    if (std::isfinite(gain)) micGain_.setGain(limit(gain));
  }
  void setAppMuted(bool muted) noexcept { appGain_.setMuted(muted); }
  void setMicMuted(bool muted) noexcept { micGain_.setMuted(muted); }

  /// The wanted (unmuted) gains, which may still be ramping.
  float appGain() const noexcept { return appGain_.gain(); }
  float micGain() const noexcept { return micGain_.gain(); }
  bool appMuted() const noexcept { return appGain_.muted(); }
  bool micMuted() const noexcept { return micGain_.muted(); }

  /// Mixes `frames` frames of `tap` (the app's audio) and `mic` into `out`.
  void process(const SourceView& tap, const SourceView& mic, const StereoOut& out,
               std::size_t frames) noexcept {
    const std::size_t tapChannels = tap.channels();
    const std::size_t micChannels = mic.channels();
    const std::size_t tapRight = tapChannels >= 2 ? 1 : 0;
    const double micChannelCount = static_cast<double>(micChannels);

    for (std::size_t f = 0; f < frames; ++f) {
      const float appGain = appGain_.next();
      const float micGain = micGain_.next();

      // A source whose gain is exactly 0 is not read at all: its samples may be huge, and
      // 0 * infinity would turn the whole frame into NaN.
      float tapL = 0.0f;
      float tapR = 0.0f;
      if (appGain != 0.0f && tapChannels > 0) {
        tapL = finite(tap.at(0, f));
        tapR = tapRight == 0 ? tapL : finite(tap.at(tapRight, f));
      }

      // The channels are summed in double, which cannot overflow for finite floats, and the
      // average of finite floats always fits a float again.
      float micPart = 0.0f;
      if (micGain != 0.0f && micChannels > 0) {
        double sum = 0.0;
        for (std::size_t c = 0; c < micChannels; ++c) sum += static_cast<double>(finite(mic.at(c, f)));
        micPart = micGain * static_cast<float>(sum / micChannelCount);
      }

      out.left[f * out.stride] = clip(appGain * tapL + micPart);
      out.right[f * out.stride] = clip(appGain * tapR + micPart);
    }
  }

 private:
  // Not valid with -ffast-math, which assumes there are no NaNs; the build must not use it.
  static float finite(float x) noexcept { return std::isfinite(x) ? x : 0.0f; }

  // Gain on a finite, enormous sample can still overflow to infinity and cancel against the other
  // source's infinity to NaN; send that to 0 rather than let a NaN out.
  static float clip(float x) noexcept {
    if (!(x == x)) return 0.0f;
    if (x > 1.0f) return 1.0f;
    if (x < -1.0f) return -1.0f;
    return x;
  }

  static float limit(float gain) noexcept {
    return gain > kMaxGain ? kMaxGain : gain;  // negatives are floored by SmoothedGain
  }

  SmoothedGain appGain_;
  SmoothedGain micGain_;
};

}  // namespace duette
