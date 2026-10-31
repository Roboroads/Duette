/*
 * duette_engine.h: the real-time mix engine, reached from Swift through this C header.
 *
 * The engine runs as the IOProc of Duette's private aggregate device. Every cycle it reads the
 * mic's and the app tap's input streams, mixes them, and writes the result to the output streams
 * of the hidden "Duette Sink", which the driver loops back to the "Duette" input device:
 *
 *   out[L,R] = clip(g_out * clip(g_app * tap[L,R] + g_mic * mono(mic)))
 *
 * Gains are 0..2 (up to +6 dB) and glide over 5 ms, so gain and mute changes never click. The
 * source meters measure the sources before their gain; the output meter measures what goes to
 * the sink.
 *
 * Threads:
 *  - duette_engine_ioproc runs on the HAL I/O thread. It does not allocate, lock, log or call
 *    into Objective-C or Swift.
 *  - Every other function is for the control side. duette_engine_configure may only be called
 *    while the engine is stopped.
 *
 * Samples are 32-bit float, the HAL's virtual format for every stream of an aggregate device.
 */
#ifndef DUETTE_ENGINE_H
#define DUETTE_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

#include <CoreAudio/AudioHardware.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// The engine. Create it once and keep it for the life of the app; it outlives every aggregate.
typedef struct duette_engine duette_engine;

typedef enum duette_status {
  DUETTE_STATUS_OK = 0,
  /// duette_engine_configure was called while the IOProc is running.
  DUETTE_STATUS_RUNNING = 1,
  /// A null pointer, a sample rate that is not positive and finite, or an empty output range.
  DUETTE_STATUS_INVALID_ARGUMENT = 2,
} duette_status;

/// The three gain stages.
typedef enum duette_source {
  /// The app tap.
  DUETTE_SOURCE_APP = 0,
  /// The microphone.
  DUETTE_SOURCE_MIC = 1,
  /// The whole mix, after app and mic are added.
  DUETTE_SOURCE_OUTPUT = 2,
} duette_source;

/// Level of one block: linear amplitude, 1.0 is full scale. The UI applies decay and hold.
typedef struct duette_level {
  float peak;
  float rms;
} duette_level;

typedef struct duette_meters {
  duette_level app;
  duette_level mic;
  duette_level output;
} duette_meters;

/// Counters kept by the IOProc. Read them from any thread.
typedef struct duette_stats {
  /// IOProc cycles since the engine was created.
  uint64_t cycles;
  /// Frames mixed since the engine was created.
  uint64_t frames;
  /// mHostTime of the output time stamp of the latest cycle (0 if the HAL gave none).
  uint64_t last_host_time;
  /// Exact-zero frames in a row at the end of the tap's input; 0 when there is no tap. A long run
  /// while the app is playing means capture permission was denied.
  uint64_t tap_zero_frames;
  /// The same for the mic.
  uint64_t mic_zero_frames;
  /// Cycles whose buffer lists did not fit the configured layout; their output was silence.
  uint64_t layout_mismatches;
  /// Processor overloads reported through duette_engine_count_overload.
  uint64_t overloads;
  /// The tap has delivered at least one non-zero sample since the last configure. A tap that
  /// never has, while its app plays, points at a denied capture permission; one that has and
  /// then goes quiet is just a quiet app.
  bool tap_had_audio;
} duette_stats;

/// A run of buffers in an AudioBufferList: `count` buffers starting at index `first`. A range
/// with `count` 0 means the source is not part of the aggregate.
typedef struct duette_range {
  uint32_t first;
  uint32_t count;
} duette_range;

/// Where each source lives in the aggregate's buffer lists. It is worked out by the control side
/// from the aggregate's streams when the aggregate is built, never assumed.
typedef struct duette_layout {
  /// The mic's buffers in the input buffer list. All its channels are averaged to mono.
  duette_range mic;
  /// The app tap's buffers in the input buffer list. Its first two channels are left and right;
  /// a single channel goes to both sides.
  duette_range tap;
  /// The sink's buffers in the output buffer list. Its first two channels get left and right.
  /// Every other output buffer is filled with silence.
  duette_range output;
  /// Nominal sample rate of the aggregate, used for the gain ramps.
  double sample_rate;
} duette_layout;

duette_engine* _Nullable duette_engine_create(void);
void duette_engine_destroy(duette_engine* _Nullable engine);

/// Sets the buffer layout. Only while stopped: returns DUETTE_STATUS_RUNNING otherwise. Resets
/// the meters and the zero runs, keeps gains, mutes and counters. The first cycle after it starts
/// at the current gains, without a ramp.
duette_status duette_engine_configure(duette_engine* engine, const duette_layout* layout);

/// Gain of one stage, limited to 0..2. NaN and infinity are ignored. Any thread, any time.
void duette_engine_set_gain(duette_engine* engine, duette_source source, float gain);
float duette_engine_gain(const duette_engine* engine, duette_source source);

/// Mutes one stage (a ramp to 0), keeping its gain for when it is unmuted. Any thread, any time.
void duette_engine_set_mute(duette_engine* engine, duette_source source, bool muted);
bool duette_engine_muted(const duette_engine* engine, duette_source source);

/// The engine's self-test tone: while on, the output is a 440 Hz sine at -12 dBFS instead of the
/// mix (cross-faded over 5 ms). Not affected by the output gain or mute.
void duette_engine_set_test_tone(duette_engine* engine, bool on);
bool duette_engine_test_tone(const duette_engine* engine);

/// Levels of the latest cycle.
void duette_engine_read_meters(const duette_engine* engine, duette_meters* meters);

void duette_engine_read_stats(const duette_engine* engine, duette_stats* stats);

/// Adds one to stats.overloads. For the control side's kAudioDeviceProcessorOverload listener.
void duette_engine_count_overload(duette_engine* engine);

/// The IOProc. Its client data is the engine. Exposed so tests can feed it synthetic buffer
/// lists; at run time it is registered by duette_engine_start.
OSStatus duette_engine_ioproc(AudioObjectID device, const AudioTimeStamp* now,
                              const AudioBufferList* input, const AudioTimeStamp* input_time,
                              AudioBufferList* output, const AudioTimeStamp* output_time,
                              void* _Nullable client_data);

/// Registers duette_engine_ioproc on `device` with AudioDeviceCreateIOProcID and starts it.
/// The engine must be configured. On success `*proc_id` holds the IOProc ID for
/// duette_engine_stop; on failure it is null and the OSStatus says why.
OSStatus duette_engine_start(duette_engine* engine, AudioObjectID device,
                             AudioDeviceIOProcID _Nullable* _Nonnull proc_id);

/// Stops the IOProc and destroys its ID, and zeroes the meters. After it returns the engine may
/// be configured again.
OSStatus duette_engine_stop(duette_engine* engine, AudioObjectID device, AudioDeviceIOProcID proc_id);

/// True between a successful duette_engine_start and the matching duette_engine_stop.
bool duette_engine_is_running(const duette_engine* engine);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DUETTE_ENGINE_H */
