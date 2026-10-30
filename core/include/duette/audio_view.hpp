#pragma once

#include <array>
#include <cstddef>

namespace duette {

/// Read-only description of the channels of one audio source, independent of how the host lays
/// them out in memory. The mixer, the meter and the zero-run detector all take one, so an
/// `AudioBufferList` with interleaved buffers, one buffer per channel, or a mix of both is
/// handled by the same code.
///
/// It only points at the caller's samples (nothing is copied or allocated) and holds up to
/// `kMaxChannels` channels; channels beyond that are left out, the rest keep working. A view
/// with no channels stands for a source that is not there. A buffer whose data pointer is null
/// is not dropped: its channels are kept as silence, so the channel count (and with it the
/// mic's average) is the one the host described.
class SourceView {
 public:
  static constexpr std::size_t kMaxChannels = 32;

  SourceView() noexcept = default;

  /// `channels` interleaved channels, the first sample of channel 0 at `data`.
  static SourceView interleaved(const float* data, std::size_t channels) noexcept {
    SourceView view;
    view.appendInterleaved(data, channels);
    return view;
  }

  /// `channels` separate buffers, one per channel. A null entry is a silent channel.
  static SourceView planar(const float* const* planes, std::size_t channels) noexcept {
    SourceView view;
    if (planes == nullptr) return view;
    for (std::size_t c = 0; c < channels; ++c) {
      if (!view.appendPlane(planes[c])) break;  // full
    }
    return view;
  }

  /// Adds the channels of one interleaved buffer after the ones already in the view. A null
  /// `data` adds silent channels. If fewer than `channels` still fit, the ones that fit are
  /// added and the call returns false, as it does for zero channels; otherwise it returns true.
  bool appendInterleaved(const float* data, std::size_t channels) noexcept {
    if (channels == 0) return false;
    const std::size_t room = kMaxChannels - count_;
    const std::size_t take = channels < room ? channels : room;
    for (std::size_t c = 0; c < take; ++c) {
      if (data != nullptr) {
        base_[count_] = data + c;
        stride_[count_] = channels;  // the stride of the real buffer, however many channels are kept
      } else {
        base_[count_] = &kSilence;
        stride_[count_] = 0;
      }
      ++count_;
    }
    return take == channels;
  }

  /// Adds one channel stored in its own buffer; a null `plane` adds a silent channel. Returns
  /// false, and adds nothing, when the view is full.
  bool appendPlane(const float* plane) noexcept {
    if (count_ == kMaxChannels) return false;
    if (plane != nullptr) {
      base_[count_] = plane;
      stride_[count_] = 1;
    } else {
      base_[count_] = &kSilence;
      stride_[count_] = 0;
    }
    ++count_;
    return true;
  }

  std::size_t channels() const noexcept { return count_; }

  /// Sample of `channel` at `frame`. The caller keeps both inside the buffers it described.
  float at(std::size_t channel, std::size_t frame) const noexcept {
    return base_[channel][frame * stride_[channel]];
  }

 private:
  static constexpr float kSilence = 0.0f;  // what a null buffer reads as: stride 0 keeps it here

  std::array<const float*, kMaxChannels> base_{};
  std::array<std::size_t, kMaxChannels> stride_{};
  std::size_t count_ = 0;
};

}  // namespace duette
