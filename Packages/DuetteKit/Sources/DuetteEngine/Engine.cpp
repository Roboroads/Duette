// The real-time mix engine behind duette_engine.h.
//
// Everything reached from duette_engine_ioproc runs on the HAL I/O thread and follows the
// real-time rules in CLAUDE.md: no allocation, no locks, no logging, no Objective-C or Swift.
// The control side talks to it through atomics only; the layout and the DSP objects are touched
// by the control side only while the IOProc is stopped.

#include "duette_engine.h"

#include <duette/audio_view.hpp>
#include <duette/mixer.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>

struct duette_engine {
  duette_layout layout{};
  bool configured = false;
  duette::Mixer mixer{48000.0f};

  std::atomic<bool> running{false};
};

namespace {

constexpr std::size_t kNoLimit = std::numeric_limits<std::size_t>::max();

const AudioBuffer* buffersOf(const AudioBufferList* list) noexcept { return list->mBuffers; }
AudioBuffer* buffersOf(AudioBufferList* list) noexcept { return list->mBuffers; }

bool inRange(const AudioBufferList* list, duette_range range) noexcept {
  if (range.count == 0) return true;
  if (list == nullptr) return false;
  const std::uint32_t n = list->mNumberBuffers;
  return range.first < n && range.count <= n - range.first;
}

std::size_t framesIn(const AudioBuffer& buffer) noexcept {
  if (buffer.mNumberChannels == 0) return 0;
  return buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels);
}

// Collects the channels of `range` into `view`. Buffers that carry data limit `frames` to what
// they hold; a buffer without data counts as silent channels and limits nothing.
void collect(const AudioBufferList* list, duette_range range, duette::SourceView& view,
             std::size_t& frames) noexcept {
  if (range.count == 0) return;
  const AudioBuffer* buffers = buffersOf(list);
  for (std::uint32_t i = range.first; i < range.first + range.count; ++i) {
    const AudioBuffer& buffer = buffers[i];
    if (buffer.mNumberChannels == 0) continue;
    if (buffer.mData != nullptr) frames = std::min(frames, framesIn(buffer));
    view.appendInterleaved(static_cast<const float*>(buffer.mData), buffer.mNumberChannels);
  }
}

// Finds where left and right go in the sink's buffers. Two channels with the same stride (one
// interleaved stereo buffer, or two mono buffers) are left and right; a single channel gets both.
bool findStereoOut(AudioBufferList* list, duette_range range, duette::StereoOut& out,
                   std::size_t& frames) noexcept {
  float* channel[2] = {nullptr, nullptr};
  std::size_t stride[2] = {0, 0};
  std::size_t found = 0;
  AudioBuffer* buffers = buffersOf(list);
  for (std::uint32_t i = range.first; i < range.first + range.count && found < 2; ++i) {
    AudioBuffer& buffer = buffers[i];
    if (buffer.mData == nullptr || buffer.mNumberChannels == 0) continue;
    frames = std::min(frames, framesIn(buffer));
    float* data = static_cast<float*>(buffer.mData);
    for (std::uint32_t c = 0; c < buffer.mNumberChannels && found < 2; ++c) {
      channel[found] = data + c;
      stride[found] = buffer.mNumberChannels;
      ++found;
    }
  }
  if (found == 0) return false;
  if (found == 2 && stride[0] == stride[1]) {
    out = duette::StereoOut{channel[0], channel[1], stride[0]};
  } else {
    // Mono sink, or channels the mixer cannot address with one stride: both sides go to the
    // first channel (the right side is written last and wins).
    out = duette::StereoOut{channel[0], channel[0], stride[0]};
  }
  return true;
}

void silence(AudioBufferList* list) noexcept {
  if (list == nullptr) return;
  AudioBuffer* buffers = buffersOf(list);
  for (std::uint32_t i = 0; i < list->mNumberBuffers; ++i) {
    if (buffers[i].mData != nullptr) std::memset(buffers[i].mData, 0, buffers[i].mDataByteSize);
  }
}

}  // namespace

extern "C" {

duette_engine* duette_engine_create(void) { return new (std::nothrow) duette_engine(); }

void duette_engine_destroy(duette_engine* engine) { delete engine; }

duette_status duette_engine_configure(duette_engine* engine, const duette_layout* layout) {
  if (engine == nullptr || layout == nullptr) return DUETTE_STATUS_INVALID_ARGUMENT;
  if (!(layout->sample_rate > 0.0) || !std::isfinite(layout->sample_rate)) {
    return DUETTE_STATUS_INVALID_ARGUMENT;
  }
  if (layout->output.count == 0) return DUETTE_STATUS_INVALID_ARGUMENT;
  if (engine->running.load(std::memory_order_acquire)) return DUETTE_STATUS_RUNNING;

  engine->layout = *layout;
  engine->mixer = duette::Mixer(static_cast<float>(layout->sample_rate));
  engine->configured = true;
  return DUETTE_STATUS_OK;
}

OSStatus duette_engine_ioproc(AudioObjectID /*device*/, const AudioTimeStamp* /*now*/,
                              const AudioBufferList* input, const AudioTimeStamp* /*input_time*/,
                              AudioBufferList* output, const AudioTimeStamp* /*output_time*/,
                              void* client_data) {
  auto* engine = static_cast<duette_engine*>(client_data);
  // Whatever is not written below must be silence, never stale data.
  silence(output);
  if (engine == nullptr || !engine->configured || output == nullptr) return noErr;
  const duette_layout& layout = engine->layout;

  if (!inRange(output, layout.output)) return noErr;
  std::size_t frames = kNoLimit;
  duette::StereoOut out;
  if (!findStereoOut(output, layout.output, out, frames)) return noErr;

  duette::SourceView mic;
  if (inRange(input, layout.mic)) collect(input, layout.mic, mic, frames);
  if (frames == kNoLimit) frames = 0;

  engine->mixer.process(duette::SourceView{}, mic, out, frames);
  return noErr;
}

OSStatus duette_engine_start(duette_engine* engine, AudioObjectID device,
                             AudioDeviceIOProcID* proc_id) {
  if (proc_id == nullptr) return kAudio_ParamError;
  *proc_id = nullptr;
  if (engine == nullptr) return kAudio_ParamError;
  if (!engine->configured || engine->running.load(std::memory_order_acquire)) {
    return kAudioHardwareIllegalOperationError;
  }

  AudioDeviceIOProcID proc = nullptr;
  OSStatus status = AudioDeviceCreateIOProcID(device, duette_engine_ioproc, engine, &proc);
  if (status != noErr) return status;
  if (proc == nullptr) return kAudioHardwareIllegalOperationError;

  // Marked running before the start so a configure racing with it is refused.
  engine->running.store(true, std::memory_order_release);
  status = AudioDeviceStart(device, proc);
  if (status != noErr) {
    AudioDeviceDestroyIOProcID(device, proc);
    engine->running.store(false, std::memory_order_release);
    return status;
  }
  *proc_id = proc;
  return noErr;
}

OSStatus duette_engine_stop(duette_engine* engine, AudioObjectID device, AudioDeviceIOProcID proc_id) {
  if (engine == nullptr) return kAudio_ParamError;
  const OSStatus stopped = AudioDeviceStop(device, proc_id);
  const OSStatus destroyed = AudioDeviceDestroyIOProcID(device, proc_id);
  engine->running.store(false, std::memory_order_release);
  return stopped != noErr ? stopped : destroyed;
}

bool duette_engine_is_running(const duette_engine* engine) {
  return engine != nullptr && engine->running.load(std::memory_order_acquire);
}

}  // extern "C"
