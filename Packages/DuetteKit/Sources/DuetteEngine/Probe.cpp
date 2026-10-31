// The loopback probe: duette_probe.h. Moved here from duettectl so the app's "Measure latency"
// and duettectl's checks run the same IOProcs and the same analysis.

#include "duette_probe.h"

#include <duette/latency_estimator.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <vector>

namespace {

constexpr double kTwoPi = 6.283185307179586476925286766559;
// Largest cycle the player renders; the HAL's buffer sizes top out well below it.
constexpr std::size_t kMaxCycleFrames = 16384;

struct ChannelSource {
  const float* data = nullptr;
  std::size_t stride = 0;
  std::size_t frames = 0;
};

// Channel `channel` counted across all buffers of `list`.
ChannelSource locate(const AudioBufferList* list, std::uint32_t channel) noexcept {
  std::uint32_t base = 0;
  for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
    const AudioBuffer& buffer = list->mBuffers[i];
    if (channel < base + buffer.mNumberChannels) {
      ChannelSource source;
      if (buffer.mData == nullptr || buffer.mNumberChannels == 0) return source;
      source.data = static_cast<const float*>(buffer.mData) + (channel - base);
      source.stride = buffer.mNumberChannels;
      source.frames = buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels);
      return source;
    }
    base += buffer.mNumberChannels;
  }
  return ChannelSource{};
}

double sampleTimeOf(const AudioTimeStamp* stamp) noexcept {
  if (stamp == nullptr || (stamp->mFlags & kAudioTimeStampSampleTimeValid) == 0) return -1.0;
  return stamp->mSampleTime;
}

void fillNow(duette_probe_block& block, const AudioTimeStamp* now) noexcept {
  block.now_sample_time = -1.0;
  block.now_host_time = 0;
  if (now == nullptr) return;
  if ((now->mFlags & kAudioTimeStampSampleTimeValid) != 0) block.now_sample_time = now->mSampleTime;
  if ((now->mFlags & kAudioTimeStampHostTimeValid) != 0) block.now_host_time = now->mHostTime;
}

}  // namespace

struct duette_probe_recorder {
  std::vector<float> samples;  // interleaved stereo ring
  std::vector<duette_probe_block> blocks;
  std::size_t capacity = 0;
  std::uint32_t firstChannel = 0;
  std::atomic<std::uint64_t> frames{0};
  std::atomic<std::uint64_t> cycles{0};
  std::atomic<std::uint32_t> channels{0};
};

struct duette_probe_player {
  std::vector<float> signal;
  std::vector<float> scratch;
  std::vector<duette_probe_block> blocks;
  double tailHz = 0.0;
  float tailAmplitude = 0.0f;
  double sampleRate = 48000.0;
  std::atomic<bool> armRequested{false};
  // Touched by the I/O thread only.
  bool started = false;
  std::int64_t position = 0;
  std::atomic<std::uint64_t> cycles{0};
};

namespace {

OSStatus recorderProc(AudioObjectID, const AudioTimeStamp* now, const AudioBufferList* input,
                      const AudioTimeStamp* inputTime, AudioBufferList*, const AudioTimeStamp*,
                      void* context) {
  auto* r = static_cast<duette_probe_recorder*>(context);
  if (r == nullptr || input == nullptr) return noErr;

  std::uint32_t total = 0;
  for (UInt32 i = 0; i < input->mNumberBuffers; ++i) total += input->mBuffers[i].mNumberChannels;
  r->channels.store(total, std::memory_order_relaxed);

  ChannelSource left = locate(input, r->firstChannel);
  ChannelSource right = locate(input, r->firstChannel + 1);
  if (right.data == nullptr) right = left;
  std::size_t n = left.data != nullptr ? left.frames : 0;
  if (right.data != nullptr && right.frames < n) n = right.frames;

  const std::uint64_t start = r->frames.load(std::memory_order_relaxed);
  for (std::size_t f = 0; f < n; ++f) {
    const std::size_t at = static_cast<std::size_t>((start + f) % r->capacity);
    r->samples[at * 2] = left.data[f * left.stride];
    r->samples[at * 2 + 1] = right.data[f * right.stride];
  }
  r->frames.store(start + n, std::memory_order_release);

  const std::uint64_t cycle = r->cycles.load(std::memory_order_relaxed);
  duette_probe_block& block = r->blocks[static_cast<std::size_t>(cycle % r->blocks.size())];
  block.sample_time = sampleTimeOf(inputTime);
  fillNow(block, now);
  block.frames = static_cast<std::uint32_t>(n);
  block.position = static_cast<std::int64_t>(start);
  r->cycles.store(cycle + 1, std::memory_order_release);
  return noErr;
}

float playerSample(const duette_probe_player& p, std::int64_t position) noexcept {
  if (position < 0) return 0.0f;
  const auto signalFrames = static_cast<std::int64_t>(p.signal.size());
  if (position < signalFrames) return p.signal[static_cast<std::size_t>(position)];
  if (p.tailAmplitude <= 0.0f || p.tailHz <= 0.0) return 0.0f;
  const double t = static_cast<double>(position - signalFrames) / p.sampleRate;
  return p.tailAmplitude * static_cast<float>(std::sin(kTwoPi * p.tailHz * t));
}

OSStatus playerProc(AudioObjectID, const AudioTimeStamp* now, const AudioBufferList*,
                    const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp* outputTime,
                    void* context) {
  auto* p = static_cast<duette_probe_player*>(context);
  if (p == nullptr || output == nullptr) return noErr;

  std::size_t frames = 0;
  for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
    const AudioBuffer& b = output->mBuffers[i];
    if (b.mData != nullptr && b.mNumberChannels > 0) {
      frames = b.mDataByteSize / (sizeof(float) * b.mNumberChannels);
      break;
    }
  }
  if (frames > kMaxCycleFrames) frames = kMaxCycleFrames;

  if (!p->started && p->armRequested.load(std::memory_order_acquire)) {
    p->started = true;
    p->position = 0;
  }
  const std::int64_t first = p->started ? p->position : -1;
  for (std::size_t f = 0; f < frames; ++f) {
    p->scratch[f] = p->started ? playerSample(*p, first + static_cast<std::int64_t>(f)) : 0.0f;
  }
  for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
    AudioBuffer& b = output->mBuffers[i];
    if (b.mData == nullptr || b.mNumberChannels == 0) continue;
    auto* out = static_cast<float*>(b.mData);
    std::size_t n = b.mDataByteSize / (sizeof(float) * b.mNumberChannels);
    if (n > frames) {
      std::memset(out + frames * b.mNumberChannels, 0,
                  (n - frames) * b.mNumberChannels * sizeof(float));
      n = frames;
    }
    for (std::size_t f = 0; f < n; ++f) {
      for (UInt32 c = 0; c < b.mNumberChannels; ++c) out[f * b.mNumberChannels + c] = p->scratch[f];
    }
  }
  if (p->started) p->position += static_cast<std::int64_t>(frames);

  const std::uint64_t cycle = p->cycles.load(std::memory_order_relaxed);
  duette_probe_block& block = p->blocks[static_cast<std::size_t>(cycle % p->blocks.size())];
  block.sample_time = sampleTimeOf(outputTime);
  fillNow(block, now);
  block.frames = static_cast<std::uint32_t>(frames);
  block.position = first;
  p->cycles.store(cycle + 1, std::memory_order_release);
  return noErr;
}

bool readBlock(const std::vector<duette_probe_block>& blocks, const std::atomic<std::uint64_t>& cycles,
               std::uint64_t index, duette_probe_block* out) {
  if (out == nullptr || blocks.empty()) return false;
  const std::uint64_t count = cycles.load(std::memory_order_acquire);
  if (index >= count || count - index > blocks.size()) return false;
  *out = blocks[static_cast<std::size_t>(index % blocks.size())];
  // The I/O thread may have overwritten it while it was copied.
  const std::uint64_t after = cycles.load(std::memory_order_acquire);
  return after - index <= blocks.size();
}

OSStatus startProc(AudioObjectID device, AudioDeviceIOProc proc, void* context,
                   AudioDeviceIOProcID* procID) {
  *procID = nullptr;
  AudioDeviceIOProcID created = nullptr;
  OSStatus status = AudioDeviceCreateIOProcID(device, proc, context, &created);
  if (status != noErr) return status;
  if (created == nullptr) return kAudioHardwareIllegalOperationError;
  status = AudioDeviceStart(device, created);
  if (status != noErr) {
    AudioDeviceDestroyIOProcID(device, created);
    return status;
  }
  *procID = created;
  return noErr;
}

}  // namespace

extern "C" {

duette_probe_recorder* duette_probe_recorder_create(size_t capacity_frames, size_t capacity_blocks,
                                              uint32_t first_channel) {
  if (capacity_frames == 0 || capacity_blocks == 0) return nullptr;
  auto* r = new (std::nothrow) duette_probe_recorder();
  if (r == nullptr) return nullptr;
  try {
    r->samples.assign(capacity_frames * 2, 0.0f);
    r->blocks.assign(capacity_blocks, duette_probe_block{});
  } catch (...) {
    delete r;
    return nullptr;
  }
  r->capacity = capacity_frames;
  r->firstChannel = first_channel;
  return r;
}

void duette_probe_recorder_destroy(duette_probe_recorder* recorder) { delete recorder; }

OSStatus duette_probe_recorder_start(duette_probe_recorder* recorder, AudioObjectID device,
                                  AudioDeviceIOProcID* proc_id) {
  if (proc_id == nullptr) return kAudio_ParamError;
  *proc_id = nullptr;
  if (recorder == nullptr) return kAudio_ParamError;
  return startProc(device, recorderProc, recorder, proc_id);
}

uint64_t duette_probe_recorder_frames(const duette_probe_recorder* recorder) {
  return recorder == nullptr ? 0 : recorder->frames.load(std::memory_order_acquire);
}

uint64_t duette_probe_recorder_cycles(const duette_probe_recorder* recorder) {
  return recorder == nullptr ? 0 : recorder->cycles.load(std::memory_order_acquire);
}

uint32_t duette_probe_recorder_input_channels(const duette_probe_recorder* recorder) {
  return recorder == nullptr ? 0 : recorder->channels.load(std::memory_order_relaxed);
}

size_t duette_probe_recorder_capacity(const duette_probe_recorder* recorder) {
  return recorder == nullptr ? 0 : recorder->capacity;
}

size_t duette_probe_recorder_copy(const duette_probe_recorder* recorder, uint64_t first_frame, float* out,
                               size_t frames) {
  if (recorder == nullptr || out == nullptr || frames == 0) return 0;
  const std::uint64_t total = recorder->frames.load(std::memory_order_acquire);
  if (first_frame >= total || total - first_frame > recorder->capacity) return 0;
  std::size_t n = static_cast<std::size_t>(total - first_frame);
  if (n > frames) n = frames;
  for (std::size_t i = 0; i < n; ++i) {
    const std::size_t at = static_cast<std::size_t>((first_frame + i) % recorder->capacity);
    out[i * 2] = recorder->samples[at * 2];
    out[i * 2 + 1] = recorder->samples[at * 2 + 1];
  }
  const std::uint64_t after = recorder->frames.load(std::memory_order_acquire);
  if (after - first_frame > recorder->capacity) return 0;  // overwritten while copying
  return n;
}

bool duette_probe_recorder_block(const duette_probe_recorder* recorder, uint64_t index,
                              duette_probe_block* out) {
  if (recorder == nullptr) return false;
  return readBlock(recorder->blocks, recorder->cycles, index, out);
}

duette_probe_player* duette_probe_player_create(const float* signal, size_t signal_frames,
                                          size_t capacity_blocks) {
  if (capacity_blocks == 0) return nullptr;
  auto* p = new (std::nothrow) duette_probe_player();
  if (p == nullptr) return nullptr;
  try {
    if (signal != nullptr && signal_frames > 0) p->signal.assign(signal, signal + signal_frames);
    p->scratch.assign(kMaxCycleFrames, 0.0f);
    p->blocks.assign(capacity_blocks, duette_probe_block{});
  } catch (...) {
    delete p;
    return nullptr;
  }
  return p;
}

void duette_probe_player_destroy(duette_probe_player* player) { delete player; }

void duette_probe_player_set_tail(duette_probe_player* player, double hz, float amplitude,
                               double sample_rate) {
  if (player == nullptr) return;
  player->tailHz = hz;
  player->tailAmplitude = amplitude;
  player->sampleRate = sample_rate > 0.0 ? sample_rate : 48000.0;
}

void duette_probe_player_arm(duette_probe_player* player) {
  if (player != nullptr) player->armRequested.store(true, std::memory_order_release);
}

OSStatus duette_probe_player_start(duette_probe_player* player, AudioObjectID device,
                                AudioDeviceIOProcID* proc_id) {
  if (proc_id == nullptr) return kAudio_ParamError;
  *proc_id = nullptr;
  if (player == nullptr) return kAudio_ParamError;
  return startProc(device, playerProc, player, proc_id);
}

uint64_t duette_probe_player_cycles(const duette_probe_player* player) {
  return player == nullptr ? 0 : player->cycles.load(std::memory_order_acquire);
}

bool duette_probe_player_block(const duette_probe_player* player, uint64_t index, duette_probe_block* out) {
  if (player == nullptr) return false;
  return readBlock(player->blocks, player->cycles, index, out);
}

OSStatus duette_probe_stop(AudioObjectID device, AudioDeviceIOProcID proc_id) {
  const OSStatus stopped = AudioDeviceStop(device, proc_id);
  const OSStatus destroyed = AudioDeviceDestroyIOProcID(device, proc_id);
  return stopped != noErr ? stopped : destroyed;
}

void duette_probe_make_chirp(float* out, size_t frames, double sample_rate, double start_hz,
                             double end_hz, float amplitude) {
  if (out == nullptr || frames == 0) return;
  const std::vector<float> chirp =
      duette::LatencyEstimator::makeChirp(sample_rate, start_hz, end_hz, frames, amplitude);
  std::copy(chirp.begin(), chirp.end(), out);
}

duette_probe_lag duette_probe_estimate_lag(const float* reference, size_t reference_frames,
                                           const float* recording, size_t recording_frames,
                                           size_t max_lag_frames) {
  const duette::LatencyResult result = duette::LatencyEstimator::estimate(
      reference, reference_frames, recording, recording_frames, max_lag_frames);
  duette_probe_lag out;
  out.lag_frames = result.lagFrames;
  out.confidence = result.confidence;
  return out;
}

}  // extern "C"
