#include "duettectl_dsp.h"

#include <duette/latency_estimator.hpp>

#include <algorithm>
#include <vector>

extern "C" void duettectl_make_chirp(float* out, size_t frames, double sample_rate, double start_hz,
                                     double end_hz, float amplitude) {
  if (out == nullptr || frames == 0) return;
  const std::vector<float> chirp =
      duette::LatencyEstimator::makeChirp(sample_rate, start_hz, end_hz, frames, amplitude);
  std::copy(chirp.begin(), chirp.end(), out);
}

extern "C" duettectl_latency duettectl_estimate_latency(const float* reference,
                                                        size_t reference_frames,
                                                        const float* recording,
                                                        size_t recording_frames,
                                                        size_t max_lag_frames) {
  const duette::LatencyResult result = duette::LatencyEstimator::estimate(
      reference, reference_frames, recording, recording_frames, max_lag_frames);
  duettectl_latency out;
  out.lag_frames = result.lagFrames;
  out.confidence = result.confidence;
  return out;
}
