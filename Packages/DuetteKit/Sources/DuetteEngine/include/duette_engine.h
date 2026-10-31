/*
 * duette_engine.h: the real-time mix engine, reached from Swift through this C header.
 *
 * The engine runs as the IOProc of Duette's private aggregate device. Every cycle it reads the
 * mic's input streams, mixes them, and writes the result to the output streams of the hidden
 * "Duette Sink", which the driver loops back to the "Duette" input device.
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
  /// The sink's buffers in the output buffer list. Its first two channels get left and right.
  /// Every other output buffer is filled with silence.
  duette_range output;
  /// Nominal sample rate of the aggregate, used for the gain ramps.
  double sample_rate;
} duette_layout;

duette_engine* _Nullable duette_engine_create(void);
void duette_engine_destroy(duette_engine* _Nullable engine);

/// Sets the buffer layout. Only while stopped: returns DUETTE_STATUS_RUNNING otherwise.
duette_status duette_engine_configure(duette_engine* engine, const duette_layout* layout);

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

/// Stops the IOProc and destroys its ID. After it returns the engine may be configured again.
OSStatus duette_engine_stop(duette_engine* engine, AudioObjectID device, AudioDeviceIOProcID proc_id);

/// True between a successful duette_engine_start and the matching duette_engine_stop.
bool duette_engine_is_running(const duette_engine* engine);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DUETTE_ENGINE_H */
