/*
 * duette_probe.h: a recorder and a player for measuring the loopback, and the DSP core's latency
 * estimator, reached from Swift.
 *
 * "Measure latency" plays a chirp into "Duette Sink" and records "Duette" while the engine is
 * paused; duettectl uses the same two IOProcs for its checks.
 *
 * The IOProcs only copy samples and store counters: no allocation, locks, logging or Swift on the
 * I/O thread. Everything they keep is preallocated when the object is created. The control side
 * reads it from any thread while they run.
 *
 * Both keep a log of their I/O cycles (sample time of the cycle's buffer, "now" when the HAL
 * called them, frame count), so the two devices can be lined up on their shared clock.
 *
 * duette_probe_make_chirp and duette_probe_estimate_lag are offline analysis: they allocate and
 * may take a while. Never call them from an audio thread.
 */
#ifndef DUETTE_PROBE_H
#define DUETTE_PROBE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <CoreAudio/AudioHardware.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// One I/O cycle.
typedef struct duette_probe_block {
  /// mSampleTime of the cycle's input time stamp (recorder) or output time stamp (player); -1 if
  /// the HAL gave none.
  double sample_time;
  /// mSampleTime and mHostTime of "now" when the HAL called the IOProc.
  double now_sample_time;
  uint64_t now_host_time;
  /// Frames in the cycle.
  uint32_t frames;
  /// Recorder: index of the cycle's first frame in the recording. Player: position of the cycle's
  /// first frame in the played stream (0 is the first frame after duette_probe_player_arm), or -1
  /// while not armed.
  int64_t position;
} duette_probe_block;

/* ---- Recorder ------------------------------------------------------------------------------ */

typedef struct duette_probe_recorder duette_probe_recorder;

/// Keeps the latest `capacity_frames` stereo frames and the latest `capacity_blocks` cycles.
/// Records input channels `first_channel` and `first_channel + 1`, counted across all of the
/// input buffers; a single channel is recorded on both sides.
duette_probe_recorder* _Nullable duette_probe_recorder_create(size_t capacity_frames,
                                                              size_t capacity_blocks,
                                                              uint32_t first_channel);
void duette_probe_recorder_destroy(duette_probe_recorder* _Nullable recorder);

/// Registers the recorder's IOProc on `device` and starts it.
OSStatus duette_probe_recorder_start(duette_probe_recorder* recorder, AudioObjectID device,
                                     AudioDeviceIOProcID _Nullable* _Nonnull proc_id);

/// Frames recorded so far (counting those no longer kept).
uint64_t duette_probe_recorder_frames(const duette_probe_recorder* recorder);
/// I/O cycles so far.
uint64_t duette_probe_recorder_cycles(const duette_probe_recorder* recorder);
/// Input channels of the latest cycle, over all buffers.
uint32_t duette_probe_recorder_input_channels(const duette_probe_recorder* recorder);
size_t duette_probe_recorder_capacity(const duette_probe_recorder* recorder);

/// Copies up to `frames` interleaved stereo frames starting at recording index `first_frame` to
/// `out` (2 floats per frame). Returns the number copied: 0 if they are not recorded yet or no
/// longer kept.
size_t duette_probe_recorder_copy(const duette_probe_recorder* recorder, uint64_t first_frame,
                                  float* out, size_t frames);

/// Cycle number `index` (0 is the first), if it is still kept.
bool duette_probe_recorder_block(const duette_probe_recorder* recorder, uint64_t index,
                                 duette_probe_block* out);

/* ---- Player -------------------------------------------------------------------------------- */

typedef struct duette_probe_player duette_probe_player;

/// Plays silence until armed, then `signal` (copied, mono, on every output channel), then the
/// tail set with duette_probe_player_set_tail (silence by default).
duette_probe_player* _Nullable duette_probe_player_create(const float* _Nullable signal,
                                                          size_t signal_frames,
                                                          size_t capacity_blocks);
void duette_probe_player_destroy(duette_probe_player* _Nullable player);

/// After the signal: a sine of `hz` with peak `amplitude` at `sample_rate`. Set it before start.
void duette_probe_player_set_tail(duette_probe_player* player, double hz, float amplitude,
                                  double sample_rate);

/// Starts the signal at the beginning of the next cycle. Any thread.
void duette_probe_player_arm(duette_probe_player* player);

OSStatus duette_probe_player_start(duette_probe_player* player, AudioObjectID device,
                                   AudioDeviceIOProcID _Nullable* _Nonnull proc_id);

uint64_t duette_probe_player_cycles(const duette_probe_player* player);
bool duette_probe_player_block(const duette_probe_player* player, uint64_t index,
                               duette_probe_block* out);

/* ---- Both ---------------------------------------------------------------------------------- */

/// Stops an IOProc started by duette_probe_recorder_start or duette_probe_player_start and
/// destroys its ID. Returns the first error.
OSStatus duette_probe_stop(AudioObjectID device, AudioDeviceIOProcID proc_id);

/* ---- Analysis (offline) -------------------------------------------------------------------- */

typedef struct duette_probe_lag {
  /// Delay of the recording relative to the reference, in frames.
  size_t lag_frames;
  /// Normalized cross-correlation at that lag, 0..1. Above about 0.5 can be trusted.
  double confidence;
} duette_probe_lag;

/// Writes `frames` samples of duette::LatencyEstimator::makeChirp: a linear sweep from
/// `start_hz` to `end_hz` with short raised-cosine fades at both ends.
void duette_probe_make_chirp(float* out, size_t frames, double sample_rate, double start_hz,
                             double end_hz, float amplitude);

/// duette::LatencyEstimator::estimate: the lag in [0, max_lag_frames] at which `recording` best
/// matches `reference`.
duette_probe_lag duette_probe_estimate_lag(const float* reference, size_t reference_frames,
                                           const float* recording, size_t recording_frames,
                                           size_t max_lag_frames);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DUETTE_PROBE_H */
