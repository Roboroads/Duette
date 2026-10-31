// The real-time mix engine behind duette_engine.h.
//
// Everything reached from duette_engine_ioproc runs on the HAL I/O thread and follows the
// real-time rules in CLAUDE.md: no allocation, no locks, no logging, no Objective-C or Swift.
// The control side talks to it through atomics only; the layout and the DSP objects are touched
// by the control side only while the IOProc is stopped.

#include "duette_engine.h"

#include <duette/audio_view.hpp>
#include <duette/mixer.hpp>
#include <duette/meter.hpp>
#include <duette/smoothed_gain.hpp>
#include <duette/tone.hpp>
#include <duette/zero_run.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>

namespace {

constexpr std::size_t kSources = 3;
constexpr float kMaxGain = duette::Mixer::kMaxGain;
constexpr float kToneFrequency = 440.0f;
constexpr float kToneAmplitude = 0.25118864f;  // -12 dBFS
constexpr double kMaxSampleRate = 1.0e6;

static_assert(std::atomic<float>::is_always_lock_free, "the real-time path must not take locks");
static_assert(std::atomic<bool>::is_always_lock_free, "the real-time path must not take locks");
static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "the real-time path must not take locks");

}  // namespace

struct duette_engine {
  duette_engine() noexcept {
    for (std::size_t i = 0; i < kSources; ++i) {
      gain[i].store(1.0f, std::memory_order_relaxed);
      muted[i].store(false, std::memory_order_relaxed);
    }
  }

  // Written by the control side only while stopped; read by the IOProc.
  duette_layout layout{};
  bool configured = false;

  // IOProc state.
  duette::Mixer mixer{48000.0f};
  duette::SmoothedGain master{48000.0f, 1.0f};
  duette::SmoothedGain toneGain{48000.0f, 0.0f};
  duette::ToneGenerator tone{48000.0f, kToneFrequency, kToneAmplitude};

  // Control side -> IOProc.
  std::atomic<float> gain[kSources];
  std::atomic<bool> muted[kSources];
  std::atomic<bool> toneOn{false};
  std::atomic<bool> running{false};

  // IOProc -> control side.
  duette::PeakRmsMeter appMeter;
  duette::PeakRmsMeter micMeter;
  std::atomic<float> outPeak{0.0f};
  std::atomic<float> outRms{0.0f};
  duette::ZeroRunDetector tapZero;
  duette::ZeroRunDetector micZero;
  std::atomic<bool> tapHadAudio{false};
  std::atomic<std::uint64_t> cycles{0};
  std::atomic<std::uint64_t> frames{0};
  std::atomic<std::uint64_t> lastHostTime{0};
  std::atomic<std::uint64_t> mismatches{0};
  std::atomic<std::uint64_t> overloads{0};
};

namespace {

constexpr std::size_t kNoLimit = std::numeric_limits<std::size_t>::max();

bool validSource(duette_source source) noexcept { return static_cast<std::size_t>(source) < kSources; }

// Only the IOProc thread writes these counters, so a load and a store is enough.
void bump(std::atomic<std::uint64_t>& counter, std::uint64_t by) noexcept {
  counter.store(counter.load(std::memory_order_relaxed) + by, std::memory_order_relaxed);
}

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

float clip(float x) noexcept {
  if (!(x == x)) return 0.0f;
  return x > 1.0f ? 1.0f : (x < -1.0f ? -1.0f : x);
}

// Copies the wanted gains and mutes into the DSP objects. Setting an unchanged value is a no-op,
// so this does not restart ramps.
void applyParameters(duette_engine& engine) noexcept {
  engine.mixer.setAppGain(engine.gain[DUETTE_SOURCE_APP].load(std::memory_order_relaxed));
  engine.mixer.setAppMuted(engine.muted[DUETTE_SOURCE_APP].load(std::memory_order_relaxed));
  engine.mixer.setMicGain(engine.gain[DUETTE_SOURCE_MIC].load(std::memory_order_relaxed));
  engine.mixer.setMicMuted(engine.muted[DUETTE_SOURCE_MIC].load(std::memory_order_relaxed));
  engine.master.setGain(engine.gain[DUETTE_SOURCE_OUTPUT].load(std::memory_order_relaxed));
  engine.master.setMuted(engine.muted[DUETTE_SOURCE_OUTPUT].load(std::memory_order_relaxed));
  engine.toneGain.setGain(engine.toneOn.load(std::memory_order_relaxed) ? 1.0f : 0.0f);
}

// A gain stage that is already at its wanted value: no ramp on the first cycle.
duette::SmoothedGain settledGain(float rate, float gain, bool muted) noexcept {
  duette::SmoothedGain stage(rate, muted ? 0.0f : gain);
  stage.setMuted(muted);  // no ramp: the target is already where it is
  stage.setGain(gain);    // remembered for unmuting; no ramp while muted
  return stage;
}

// Meters read zero until the next cycle measures something.
void clearMeters(duette_engine& engine) noexcept {
  const duette::SourceView nothing;
  engine.appMeter.update(nothing, 1);
  engine.micMeter.update(nothing, 1);
  engine.outPeak.store(0.0f, std::memory_order_relaxed);
  engine.outRms.store(0.0f, std::memory_order_relaxed);
}

// The mixer starts at unity gain. Running it on silence for a little over one ramp makes it
// arrive at the wanted gains before the first real cycle.
void settle(duette::Mixer& mixer, double rate) noexcept {
  float scratch[2 * 64];
  std::size_t remaining = static_cast<std::size_t>(std::ceil(rate * 0.005)) + 2;
  while (remaining > 0) {
    const std::size_t n = std::min<std::size_t>(remaining, 64);
    mixer.process(duette::SourceView{}, duette::SourceView{}, duette::StereoOut::interleaved(scratch), n);
    remaining -= n;
  }
}

}  // namespace

extern "C" {

duette_engine* duette_engine_create(void) { return new (std::nothrow) duette_engine(); }

void duette_engine_destroy(duette_engine* engine) { delete engine; }

duette_status duette_engine_configure(duette_engine* engine, const duette_layout* layout) {
  if (engine == nullptr || layout == nullptr) return DUETTE_STATUS_INVALID_ARGUMENT;
  if (!(layout->sample_rate > 0.0) || !(layout->sample_rate <= kMaxSampleRate)) {
    return DUETTE_STATUS_INVALID_ARGUMENT;
  }
  if (layout->output.count == 0) return DUETTE_STATUS_INVALID_ARGUMENT;
  if (engine->running.load(std::memory_order_acquire)) return DUETTE_STATUS_RUNNING;

  const float rate = static_cast<float>(layout->sample_rate);
  engine->layout = *layout;
  engine->mixer = duette::Mixer(rate);
  applyParameters(*engine);
  settle(engine->mixer, layout->sample_rate);
  engine->master = settledGain(rate, engine->gain[DUETTE_SOURCE_OUTPUT].load(std::memory_order_relaxed),
                               engine->muted[DUETTE_SOURCE_OUTPUT].load(std::memory_order_relaxed));
  engine->toneGain = duette::SmoothedGain(rate, engine->toneOn.load(std::memory_order_relaxed) ? 1.0f : 0.0f);
  engine->tone = duette::ToneGenerator(rate, kToneFrequency, kToneAmplitude);

  clearMeters(*engine);
  engine->tapZero.reset();
  engine->micZero.reset();
  engine->tapHadAudio.store(false, std::memory_order_relaxed);
  engine->configured = true;
  return DUETTE_STATUS_OK;
}

void duette_engine_set_gain(duette_engine* engine, duette_source source, float gain) {
  if (engine == nullptr || !validSource(source) || !std::isfinite(gain)) return;
  engine->gain[source].store(std::min(std::max(gain, 0.0f), kMaxGain), std::memory_order_relaxed);
}

float duette_engine_gain(const duette_engine* engine, duette_source source) {
  if (engine == nullptr || !validSource(source)) return 0.0f;
  return engine->gain[source].load(std::memory_order_relaxed);
}

void duette_engine_set_mute(duette_engine* engine, duette_source source, bool muted) {
  if (engine == nullptr || !validSource(source)) return;
  engine->muted[source].store(muted, std::memory_order_relaxed);
}

bool duette_engine_muted(const duette_engine* engine, duette_source source) {
  if (engine == nullptr || !validSource(source)) return false;
  return engine->muted[source].load(std::memory_order_relaxed);
}

void duette_engine_set_test_tone(duette_engine* engine, bool on) {
  if (engine != nullptr) engine->toneOn.store(on, std::memory_order_relaxed);
}

bool duette_engine_test_tone(const duette_engine* engine) {
  return engine != nullptr && engine->toneOn.load(std::memory_order_relaxed);
}

void duette_engine_read_meters(const duette_engine* engine, duette_meters* meters) {
  if (meters == nullptr) return;
  *meters = duette_meters{};
  if (engine == nullptr) return;
  meters->app = duette_level{engine->appMeter.peak(), engine->appMeter.rms()};
  meters->mic = duette_level{engine->micMeter.peak(), engine->micMeter.rms()};
  meters->output = duette_level{engine->outPeak.load(std::memory_order_relaxed),
                                engine->outRms.load(std::memory_order_relaxed)};
}

void duette_engine_read_stats(const duette_engine* engine, duette_stats* stats) {
  if (stats == nullptr) return;
  *stats = duette_stats{};
  if (engine == nullptr) return;
  stats->cycles = engine->cycles.load(std::memory_order_relaxed);
  stats->frames = engine->frames.load(std::memory_order_relaxed);
  stats->last_host_time = engine->lastHostTime.load(std::memory_order_relaxed);
  // configure resets both runs, and a source that is not in the layout never updates its run,
  // so an absent source reads 0 without touching the layout (which this thread may not read).
  stats->tap_zero_frames = engine->tapZero.zeroFrames();
  stats->mic_zero_frames = engine->micZero.zeroFrames();
  stats->layout_mismatches = engine->mismatches.load(std::memory_order_relaxed);
  stats->overloads = engine->overloads.load(std::memory_order_relaxed);
  stats->tap_had_audio = engine->tapHadAudio.load(std::memory_order_relaxed);
}

void duette_engine_count_overload(duette_engine* engine) {
  if (engine != nullptr) engine->overloads.fetch_add(1, std::memory_order_relaxed);
}

OSStatus duette_engine_ioproc(AudioObjectID /*device*/, const AudioTimeStamp* now,
                              const AudioBufferList* input, const AudioTimeStamp* /*input_time*/,
                              AudioBufferList* output, const AudioTimeStamp* output_time,
                              void* client_data) {
  auto* engine = static_cast<duette_engine*>(client_data);
  // Whatever is not written below must be silence, never stale data.
  silence(output);
  if (engine == nullptr || !engine->configured || output == nullptr) return noErr;
  duette_engine& e = *engine;
  const duette_layout& layout = e.layout;

  bump(e.cycles, 1);
  if (output_time != nullptr && (output_time->mFlags & kAudioTimeStampHostTimeValid) != 0) {
    e.lastHostTime.store(output_time->mHostTime, std::memory_order_relaxed);
  } else if (now != nullptr && (now->mFlags & kAudioTimeStampHostTimeValid) != 0) {
    e.lastHostTime.store(now->mHostTime, std::memory_order_relaxed);
  }

  std::size_t frames = kNoLimit;
  duette::StereoOut out;
  if (!inRange(output, layout.output) || !findStereoOut(output, layout.output, out, frames)) {
    bump(e.mismatches, 1);
    return noErr;
  }

  duette::SourceView mic;
  duette::SourceView tap;
  bool mismatch = false;
  if (inRange(input, layout.mic)) {
    collect(input, layout.mic, mic, frames);
  } else {
    mismatch = true;
  }
  if (inRange(input, layout.tap)) {
    collect(input, layout.tap, tap, frames);
  } else {
    mismatch = true;
  }
  if (mismatch) bump(e.mismatches, 1);
  if (frames == kNoLimit) frames = 0;

  applyParameters(e);

  // Source levels before their gain, so a muted mic still shows it is picking something up.
  e.appMeter.update(tap, frames);
  e.micMeter.update(mic, frames);
  if (tap.channels() > 0 && frames > 0) {
    e.tapZero.update(tap, frames);
    // A run shorter than this block means one of its samples was not zero.
    if (e.tapZero.zeroFrames() < frames && !e.tapHadAudio.load(std::memory_order_relaxed)) {
      e.tapHadAudio.store(true, std::memory_order_relaxed);
    }
  }
  if (mic.channels() > 0) e.micZero.update(mic, frames);

  e.mixer.process(tap, mic, out, frames);

  // Output gain, then the test tone cross-fade, then the final clip; metered as it leaves.
  float peak = 0.0f;
  double sumSquares = 0.0;
  for (std::size_t f = 0; f < frames; ++f) {
    const float g = e.master.next();
    const float t = e.toneGain.next();
    float left = out.left[f * out.stride] * g;
    float right = out.right[f * out.stride] * g;
    if (t != 0.0f) {
      const float s = e.tone.next();
      left = left * (1.0f - t) + s * t;
      right = right * (1.0f - t) + s * t;
    }
    left = clip(left);
    right = clip(right);
    out.left[f * out.stride] = left;
    out.right[f * out.stride] = right;
    peak = std::max(peak, std::max(std::fabs(left), std::fabs(right)));
    sumSquares += static_cast<double>(left) * left + static_cast<double>(right) * right;
  }
  const double samples = frames > 0 ? 2.0 * static_cast<double>(frames) : 1.0;
  e.outPeak.store(peak, std::memory_order_relaxed);
  e.outRms.store(static_cast<float>(std::sqrt(sumSquares / samples)), std::memory_order_relaxed);
  bump(e.frames, frames);
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
  // The IOProc no longer runs, so nothing else writes the meters now.
  clearMeters(*engine);
  engine->running.store(false, std::memory_order_release);
  return stopped != noErr ? stopped : destroyed;
}

bool duette_engine_is_running(const duette_engine* engine) {
  return engine != nullptr && engine->running.load(std::memory_order_acquire);
}

}  // extern "C"
