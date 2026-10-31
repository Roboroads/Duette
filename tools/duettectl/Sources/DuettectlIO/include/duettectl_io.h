/*
 * duettectl_io.h: IOProcs that record from a device's input and play into a device's output,
 * for duettectl's checks.
 *
 * The IOProcs only copy samples and store counters: no allocation, locks, logging or Swift on the
 * I/O thread. Everything they keep is preallocated when the object is created. The control side
 * reads it from any thread while they run.
 *
 * Both keep a log of their I/O cycles (sample time of the cycle's buffer, "now" when the HAL
 * called them, frame count), so a check can line the two devices up on their shared clock.
 */
#ifndef DUETTECTL_IO_H
#define DUETTECTL_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <CoreAudio/AudioHardware.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// One I/O cycle.
typedef struct duettectl_block {
  /// mSampleTime of the cycle's input time stamp (recorder) or output time stamp (player); -1 if
  /// the HAL gave none.
  double sample_time;
  /// mSampleTime and mHostTime of "now" when the HAL called the IOProc.
  double now_sample_time;
  uint64_t now_host_time;
  /// Frames in the cycle.
  uint32_t frames;
  /// Recorder: index of the cycle's first frame in the recording. Player: position of the cycle's
  /// first frame in the played stream (0 is the first frame after duettectl_player_arm), or -1
  /// while not armed.
  int64_t position;
} duettectl_block;

/* ---- Recorder ------------------------------------------------------------------------------ */

typedef struct duettectl_recorder duettectl_recorder;

/// Keeps the latest `capacity_frames` stereo frames and the latest `capacity_blocks` cycles.
/// Records input channels `first_channel` and `first_channel + 1`, counted across all of the
/// input buffers; a single channel is recorded on both sides.
duettectl_recorder* _Nullable duettectl_recorder_create(size_t capacity_frames,
                                                        size_t capacity_blocks,
                                                        uint32_t first_channel);
void duettectl_recorder_destroy(duettectl_recorder* _Nullable recorder);

/// Registers the recorder's IOProc on `device` and starts it.
OSStatus duettectl_recorder_start(duettectl_recorder* recorder, AudioObjectID device,
                                  AudioDeviceIOProcID _Nullable* _Nonnull proc_id);

/// Frames recorded so far (counting those no longer kept).
uint64_t duettectl_recorder_frames(const duettectl_recorder* recorder);
/// I/O cycles so far.
uint64_t duettectl_recorder_cycles(const duettectl_recorder* recorder);
/// Input channels of the latest cycle, over all buffers.
uint32_t duettectl_recorder_input_channels(const duettectl_recorder* recorder);
size_t duettectl_recorder_capacity(const duettectl_recorder* recorder);

/// Copies up to `frames` interleaved stereo frames starting at recording index `first_frame` to
/// `out` (2 floats per frame). Returns the number copied: 0 if they are not recorded yet or no
/// longer kept.
size_t duettectl_recorder_copy(const duettectl_recorder* recorder, uint64_t first_frame,
                               float* out, size_t frames);

/// Cycle number `index` (0 is the first), if it is still kept.
bool duettectl_recorder_block(const duettectl_recorder* recorder, uint64_t index,
                              duettectl_block* out);

/* ---- Player -------------------------------------------------------------------------------- */

typedef struct duettectl_player duettectl_player;

/// Plays silence until armed, then `signal` (copied, mono, on every output channel), then the
/// tail set with duettectl_player_set_tail (silence by default).
duettectl_player* _Nullable duettectl_player_create(const float* _Nullable signal,
                                                    size_t signal_frames, size_t capacity_blocks);
void duettectl_player_destroy(duettectl_player* _Nullable player);

/// After the signal: a sine of `hz` with peak `amplitude` at `sample_rate`. Set it before start.
void duettectl_player_set_tail(duettectl_player* player, double hz, float amplitude,
                               double sample_rate);

/// Starts the signal at the beginning of the next cycle. Any thread.
void duettectl_player_arm(duettectl_player* player);

OSStatus duettectl_player_start(duettectl_player* player, AudioObjectID device,
                                AudioDeviceIOProcID _Nullable* _Nonnull proc_id);

uint64_t duettectl_player_cycles(const duettectl_player* player);
bool duettectl_player_block(const duettectl_player* player, uint64_t index, duettectl_block* out);

/* ---- Both ---------------------------------------------------------------------------------- */

/// Stops an IOProc started by duettectl_recorder_start or duettectl_player_start and destroys
/// its ID. Returns the first error.
OSStatus duettectl_io_stop(AudioObjectID device, AudioDeviceIOProcID proc_id);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DUETTECTL_IO_H */
