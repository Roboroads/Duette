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
/// `kMaxChannels` channels. A view with no channels stands for a source that is not there.
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

  /// `channels` separate buffers, one per channel.
  static SourceView planar(const float* const* planes, std::size_t channels) noexcept {
    SourceView view;
    if (planes == nullptr) return view;
    for (std::size_t c = 0; c < channels; ++c) {
      if (!view.appendPlane(planes[c])) break;
    }
    return view;
  }

  /// Adds the channels of one interleaved buffer after the ones already in the view. Returns
  /// false, and adds nothing, for a null buffer, zero channels, or when they would not fit.
  bool appendInterleaved(const float* data, std::size_t channels) noexcept {
    if (data == nullptr || channels == 0 || channels > kMaxChannels - count_) return false;
    for (std::size_t c = 0; c < channels; ++c) {
      base_[count_] = data + c;
      stride_[count_] = channels;
      ++count_;
    }
    return true;
  }

  /// Adds one channel stored in its own buffer. Returns false, and adds nothing, for a null
  /// buffer or a full view.
  bool appendPlane(const float* plane) noexcept {
    if (plane == nullptr || count_ == kMaxChannels) return false;
    base_[count_] = plane;
    stride_[count_] = 1;
    ++count_;
    return true;
  }

  std::size_t channels() const noexcept { return count_; }

  /// Sample of `channel` at `frame`. The caller keeps both inside the buffers it described.
  float at(std::size_t channel, std::size_t frame) const noexcept {
    return base_[channel][frame * stride_[channel]];
  }

 private:
  std::array<const float*, kMaxChannels> base_{};
  std::array<std::size_t, kMaxChannels> stride_{};
  std::size_t count_ = 0;
};

}  // namespace duette
