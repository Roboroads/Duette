/*
 * duettectl_dsp.h: the parts of the DSP core (core/include/duette) that duettectl calls from
 * Swift. Offline analysis only: these allocate and may take a while. Never call them from an
 * audio thread. No Apple headers, so the functions are the same everywhere.
 */
#ifndef DUETTECTL_DSP_H
#define DUETTECTL_DSP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct duettectl_latency {
  /// Delay of the recording relative to the reference, in frames.
  size_t lag_frames;
  /// Normalized cross-correlation at that lag, 0..1. Above about 0.5 can be trusted.
  double confidence;
} duettectl_latency;

/// Writes `frames` samples of duette::LatencyEstimator::makeChirp: a linear sweep from
/// `start_hz` to `end_hz` with short raised-cosine fades at both ends.
void duettectl_make_chirp(float* out, size_t frames, double sample_rate, double start_hz,
                          double end_hz, float amplitude);

/// duette::LatencyEstimator::estimate: the lag in [0, max_lag_frames] at which `recording` best
/// matches `reference`.
duettectl_latency duettectl_estimate_latency(const float* reference, size_t reference_frames,
                                             const float* recording, size_t recording_frames,
                                             size_t max_lag_frames);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DUETTECTL_DSP_H */
