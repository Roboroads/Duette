#include <duette/audio_view.hpp>
#include <duette/mixer.hpp>

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

using duette::Mixer;
using duette::SourceView;
using duette::StereoOut;

namespace {

constexpr std::size_t kRamp = 240;  // 5 ms at 48 kHz

// Planar test signal: channel c, frame f.
std::vector<std::vector<float>> makePlanar(std::size_t channels, std::size_t frames, float seed = 0.0f) {
  std::vector<std::vector<float>> p(channels, std::vector<float>(frames));
  for (std::size_t c = 0; c < channels; ++c) {
    for (std::size_t f = 0; f < frames; ++f) {
      p[c][f] = 0.3f * std::sin(0.05f * static_cast<float>(f) + static_cast<float>(c) * 1.3f + seed);
    }
  }
  return p;
}

std::vector<float> interleave(const std::vector<std::vector<float>>& planar) {
  const std::size_t channels = planar.size();
  const std::size_t frames = planar.empty() ? 0 : planar[0].size();
  std::vector<float> out(channels * frames);
  for (std::size_t f = 0; f < frames; ++f) {
    for (std::size_t c = 0; c < channels; ++c) out[f * channels + c] = planar[c][f];
  }
  return out;
}

SourceView planarView(const std::vector<std::vector<float>>& planar, std::vector<const float*>& ptrs) {
  ptrs.clear();
  for (const auto& ch : planar) ptrs.push_back(ch.data());
  return SourceView::planar(ptrs.data(), ptrs.size());
}

struct Stereo {
  std::vector<float> l, r;
};

// Runs the mixer on constant-per-channel input and returns the last block's output.
Stereo mix(Mixer& m, const SourceView& tap, const SourceView& mic, std::size_t frames) {
  std::vector<float> out(frames * 2);
  m.process(tap, mic, StereoOut::interleaved(out.data()), frames);
  Stereo s;
  for (std::size_t f = 0; f < frames; ++f) {
    s.l.push_back(out[2 * f]);
    s.r.push_back(out[2 * f + 1]);
  }
  return s;
}

// Lets any gain ramp finish, so tests can look at steady-state output.
void settle(Mixer& m) {
  std::vector<float> out((kRamp + 8) * 2);
  m.process(SourceView{}, SourceView{}, StereoOut::interleaved(out.data()), kRamp + 8);
}

}  // namespace

TEST_CASE("source views describe interleaved and planar channels", "[mixer][view]") {
  const float inter[6] = {1, 2, 3, 4, 5, 6};  // 3 frames of 2 channels
  const auto a = SourceView::interleaved(inter, 2);
  CHECK(a.channels() == 2);
  CHECK(a.at(0, 0) == 1.0f);
  CHECK(a.at(1, 0) == 2.0f);
  CHECK(a.at(0, 2) == 5.0f);
  CHECK(a.at(1, 2) == 6.0f);

  const float l[3] = {1, 3, 5};
  const float r[3] = {2, 4, 6};
  const float* planes[2] = {l, r};
  const auto b = SourceView::planar(planes, 2);
  CHECK(b.channels() == 2);
  for (std::size_t f = 0; f < 3; ++f) {
    CHECK(a.at(0, f) == b.at(0, f));
    CHECK(a.at(1, f) == b.at(1, f));
  }

  CHECK(SourceView{}.channels() == 0);
  CHECK(SourceView::interleaved(nullptr, 2).channels() == 0);
  CHECK(SourceView::interleaved(inter, 0).channels() == 0);
}

TEST_CASE("a view can be built from several buffers", "[mixer][view]") {
  // Like an AudioBufferList with a mono interleaved buffer followed by a stereo one.
  const float mono[2] = {10, 11};
  const float stereo[4] = {20, 21, 30, 31};
  SourceView v;
  CHECK(v.appendInterleaved(mono, 1));
  CHECK(v.appendInterleaved(stereo, 2));
  CHECK(v.channels() == 3);
  CHECK(v.at(0, 1) == 11.0f);
  CHECK(v.at(1, 1) == 30.0f);
  CHECK(v.at(2, 1) == 31.0f);

  CHECK_FALSE(v.appendInterleaved(nullptr, 2));
  CHECK_FALSE(v.appendPlane(nullptr));
  CHECK(v.channels() == 3);

  // Capacity is fixed; running out is reported, never a crash or an overwrite.
  SourceView full;
  for (std::size_t i = 0; i < SourceView::kMaxChannels; ++i) CHECK(full.appendPlane(mono));
  CHECK_FALSE(full.appendPlane(mono));
  CHECK_FALSE(full.appendInterleaved(stereo, 2));
  CHECK(full.channels() == SourceView::kMaxChannels);
}

TEST_CASE("a mono mic is sent to both sides", "[mixer]") {
  Mixer m;
  const float mic[4] = {0.25f, -0.5f, 0.0f, 0.75f};
  const auto s = mix(m, SourceView{}, SourceView::interleaved(mic, 1), 4);
  for (std::size_t f = 0; f < 4; ++f) {
    CHECK(s.l[f] == mic[f]);
    CHECK(s.r[f] == mic[f]);
  }
}

TEST_CASE("a multichannel mic is averaged to mono", "[mixer]") {
  Mixer m;
  const float stereo[4] = {0.5f, 0.1f, -0.2f, 0.6f};  // 2 frames
  auto s = mix(m, SourceView{}, SourceView::interleaved(stereo, 2), 2);
  CHECK(s.l[0] == Catch::Approx(0.3f));
  CHECK(s.r[0] == Catch::Approx(0.3f));
  CHECK(s.l[1] == Catch::Approx(0.2f));
  CHECK(s.r[1] == Catch::Approx(0.2f));

  const float quad[4] = {0.4f, 0.0f, -0.4f, 0.8f};  // 1 frame of 4 channels
  s = mix(m, SourceView{}, SourceView::interleaved(quad, 4), 1);
  CHECK(s.l[0] == Catch::Approx(0.2f));
  CHECK(s.r[0] == Catch::Approx(0.2f));
}

TEST_CASE("a mono tap is duplicated to both sides", "[mixer]") {
  Mixer m;
  const float tap[3] = {0.1f, -0.6f, 0.9f};
  const auto s = mix(m, SourceView::interleaved(tap, 1), SourceView{}, 3);
  for (std::size_t f = 0; f < 3; ++f) {
    CHECK(s.l[f] == tap[f]);
    CHECK(s.r[f] == tap[f]);
  }
}

TEST_CASE("a stereo tap keeps its sides, extra tap channels are ignored", "[mixer]") {
  Mixer m;
  const float stereo[4] = {0.1f, -0.3f, 0.5f, 0.2f};
  auto s = mix(m, SourceView::interleaved(stereo, 2), SourceView{}, 2);
  CHECK(s.l[0] == 0.1f);
  CHECK(s.r[0] == -0.3f);
  CHECK(s.l[1] == 0.5f);
  CHECK(s.r[1] == 0.2f);

  const float three[3] = {0.1f, -0.3f, 0.9f};
  s = mix(m, SourceView::interleaved(three, 3), SourceView{}, 1);
  CHECK(s.l[0] == 0.1f);
  CHECK(s.r[0] == -0.3f);
}

TEST_CASE("tap and mic are summed", "[mixer]") {
  Mixer m;
  const float tap[2] = {0.2f, -0.1f};  // 1 frame, stereo
  const float mic[1] = {0.3f};
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 1), 1);
  CHECK(s.l[0] == Catch::Approx(0.5f));
  CHECK(s.r[0] == Catch::Approx(0.2f));
}

TEST_CASE("interleaved and non-interleaved inputs and outputs give identical output", "[mixer]") {
  constexpr std::size_t kFrames = 700;
  const auto tapP = makePlanar(2, kFrames, 0.1f);
  const auto micP = makePlanar(4, kFrames, 0.7f);  // a 4-channel interface
  const auto tapI = interleave(tapP);
  const auto micI = interleave(micP);
  std::vector<const float*> tp, mp;

  auto configure = [](Mixer& m) {
    m.setAppGain(0.8f);
    m.setMicGain(1.5f);
  };

  Mixer a, b, c;
  configure(a);
  configure(b);
  configure(c);

  std::vector<float> outInterleaved(kFrames * 2);
  a.process(SourceView::interleaved(tapI.data(), 2), SourceView::interleaved(micI.data(), 4),
            StereoOut::interleaved(outInterleaved.data()), kFrames);

  std::vector<float> l(kFrames), r(kFrames);
  b.process(planarView(tapP, tp), planarView(micP, mp), StereoOut::planar(l.data(), r.data()), kFrames);

  // Mixed layouts: planar tap with interleaved mic, written interleaved.
  std::vector<float> outMixed(kFrames * 2);
  c.process(planarView(tapP, tp), SourceView::interleaved(micI.data(), 4),
            StereoOut::interleaved(outMixed.data()), kFrames);

  for (std::size_t f = 0; f < kFrames; ++f) {
    REQUIRE(outInterleaved[2 * f] == l[f]);
    REQUIRE(outInterleaved[2 * f + 1] == r[f]);
    REQUIRE(outMixed[2 * f] == l[f]);
    REQUIRE(outMixed[2 * f + 1] == r[f]);
  }
}

TEST_CASE("a source with no channels is silence", "[mixer]") {
  Mixer m;
  const float tap[2] = {0.4f, -0.2f};
  const float mic[1] = {0.1f};

  auto s = mix(m, SourceView::interleaved(tap, 2), SourceView{}, 1);  // no mic
  CHECK(s.l[0] == 0.4f);
  CHECK(s.r[0] == -0.2f);

  s = mix(m, SourceView{}, SourceView::interleaved(mic, 1), 1);  // no tap
  CHECK(s.l[0] == 0.1f);
  CHECK(s.r[0] == 0.1f);

  s = mix(m, SourceView{}, SourceView{}, 5);  // neither
  for (std::size_t f = 0; f < 5; ++f) {
    CHECK(s.l[f] == 0.0f);
    CHECK(s.r[f] == 0.0f);
  }
}

TEST_CASE("the mix is hard-clipped at plus and minus one", "[mixer]") {
  Mixer m;
  const float tap[6] = {0.9f, -0.9f, 1.5f, -1.5f, 1.0f, -1.0f};  // 3 stereo frames
  const float mic[3] = {0.5f, -0.5f, 0.0f};
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 1), 3);
  CHECK(s.l[0] == 1.0f);                         // 0.9 + 0.5 clips
  CHECK(s.r[0] == Catch::Approx(-0.4f));         // -0.9 + 0.5 does not
  CHECK(s.l[1] == 1.0f);                         // 1.5 - 0.5 is exactly the limit
  CHECK(s.r[1] == -1.0f);                        // -1.5 - 0.5 clips
  CHECK(s.l[2] == 1.0f);
  CHECK(s.r[2] == -1.0f);
}

TEST_CASE("clipping applies after the gains", "[mixer]") {
  Mixer m;
  m.setAppGain(2.0f);
  settle(m);
  const float tap[2] = {0.4f, -0.4f};
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView{}, 1);
  CHECK(s.l[0] == Catch::Approx(0.8f));
  CHECK(s.r[0] == Catch::Approx(-0.8f));

  const float loud[2] = {0.9f, -0.9f};
  const auto c = mix(m, SourceView::interleaved(loud, 2), SourceView{}, 1);
  CHECK(c.l[0] == 1.0f);
  CHECK(c.r[0] == -1.0f);
}

TEST_CASE("gain 0 gives exact zeros", "[mixer]") {
  Mixer m;
  m.setAppGain(0.0f);
  m.setMicGain(0.0f);
  settle(m);
  const auto tapP = makePlanar(2, 300);
  const auto micP = makePlanar(2, 300, 1.0f);
  const auto tapI = interleave(tapP);
  const auto micI = interleave(micP);
  const auto s = mix(m, SourceView::interleaved(tapI.data(), 2), SourceView::interleaved(micI.data(), 2), 300);
  for (std::size_t f = 0; f < 300; ++f) {
    REQUIRE(s.l[f] == 0.0f);
    REQUIRE(s.r[f] == 0.0f);
  }
}

TEST_CASE("mute gives exact zeros for that source", "[mixer]") {
  const float tap[2] = {0.4f, -0.3f};
  const float mic[1] = {0.1f};

  Mixer m;
  m.setAppMuted(true);
  settle(m);
  auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 1), 1);
  CHECK(s.l[0] == 0.1f);  // only the mic is left
  CHECK(s.r[0] == 0.1f);

  m.setAppMuted(false);
  m.setMicMuted(true);
  settle(m);
  s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 1), 1);
  CHECK(s.l[0] == 0.4f);
  CHECK(s.r[0] == -0.3f);

  m.setAppMuted(true);
  settle(m);
  s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 1), 1);
  CHECK(s.l[0] == 0.0f);
  CHECK(s.r[0] == 0.0f);
}

TEST_CASE("gains scale their own source only", "[mixer]") {
  Mixer m;
  m.setAppGain(0.5f);
  m.setMicGain(1.5f);
  settle(m);
  const float tap[2] = {0.4f, -0.2f};
  const float mic[2] = {0.1f, 0.3f};  // averages to 0.2
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 2), 1);
  CHECK(s.l[0] == Catch::Approx(0.4f * 0.5f + 0.2f * 1.5f));
  CHECK(s.r[0] == Catch::Approx(-0.2f * 0.5f + 0.2f * 1.5f));
}

TEST_CASE("gains are limited to 0..2 and bad values are ignored", "[mixer]") {
  Mixer m;
  m.setAppGain(5.0f);
  CHECK(m.appGain() == 2.0f);
  m.setAppGain(-1.0f);
  CHECK(m.appGain() == 0.0f);
  m.setAppGain(0.75f);
  m.setAppGain(std::numeric_limits<float>::quiet_NaN());
  CHECK(m.appGain() == 0.75f);

  m.setMicGain(9.0f);
  CHECK(m.micGain() == 2.0f);
  m.setMicGain(0.5f);
  m.setMicGain(std::numeric_limits<float>::infinity());
  CHECK(m.micGain() == 0.5f);
}

TEST_CASE("a gain change ramps over 5 ms instead of stepping", "[mixer]") {
  Mixer m;
  m.setAppGain(0.0f);
  const std::size_t n = kRamp + 20;
  const std::vector<float> tap(n, 1.0f);
  const auto s = mix(m, SourceView::interleaved(tap.data(), 1), SourceView{}, n);

  CHECK(s.l[0] < 1.0f);
  CHECK(s.l[0] > 1.0f - 2.0f / static_cast<float>(kRamp));  // first step is small
  for (std::size_t f = 1; f < kRamp; ++f) {
    REQUIRE(s.l[f] <= s.l[f - 1]);
    REQUIRE(s.l[f - 1] - s.l[f] <= 1.0f / static_cast<float>(kRamp) + 1e-6f);
  }
  CHECK(s.l[kRamp - 1] == 0.0f);  // exactly zero when the ramp is done
  CHECK(s.l[n - 1] == 0.0f);
  CHECK(s.l == s.r);
}

TEST_CASE("unmuting ramps up from zero", "[mixer]") {
  Mixer m;
  m.setMicMuted(true);
  settle(m);
  m.setMicMuted(false);
  const std::size_t n = kRamp;
  const std::vector<float> mic(n, 1.0f);
  const auto s = mix(m, SourceView{}, SourceView::interleaved(mic.data(), 1), n);
  CHECK(s.l[0] > 0.0f);
  CHECK(s.l[0] < 0.01f);
  for (std::size_t f = 1; f < n; ++f) REQUIRE(s.l[f] >= s.l[f - 1]);
  CHECK(s.l[n - 1] == 1.0f);
}

TEST_CASE("non-finite input samples are treated as zero", "[mixer]") {
  const float nan = std::numeric_limits<float>::quiet_NaN();
  const float inf = std::numeric_limits<float>::infinity();

  Mixer m;
  // Tap: NaN on the left of frame 0, inf on the right of frame 1.
  const float tap[6] = {nan, 0.25f, 0.5f, inf, 0.1f, -0.1f};
  // Mic: stereo, NaN in one channel of frame 2 so only the other channel counts.
  const float mic[6] = {0.0f, 0.0f, 0.0f, 0.0f, nan, 0.4f};
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 2), 3);
  for (std::size_t f = 0; f < 3; ++f) {
    REQUIRE(std::isfinite(s.l[f]));
    REQUIRE(std::isfinite(s.r[f]));
  }
  CHECK(s.l[0] == 0.0f);
  CHECK(s.r[0] == 0.25f);
  CHECK(s.l[1] == 0.5f);
  CHECK(s.r[1] == 0.0f);
  CHECK(s.l[2] == Catch::Approx(0.1f + 0.2f));
  CHECK(s.r[2] == Catch::Approx(-0.1f + 0.2f));
}

TEST_CASE("huge finite inputs cannot produce NaN", "[mixer]") {
  Mixer m;
  m.setAppGain(2.0f);
  m.setMicGain(2.0f);
  settle(m);
  const float big = std::numeric_limits<float>::max();
  // Left: tap gain overflows towards +inf while the mic sum overflows to -inf. Without fused
  // multiply-add that is inf + -inf = NaN, which the mixer turns into 0; with it (arm64, or x86
  // with FMA enabled) the sum is -inf, which clips to -1. Which one happens depends on the
  // compiler, so the guarantee checked here is only that the output is a valid sample.
  const float tap[2] = {big, -big};
  const float mic[2] = {-big, -big};
  const auto s = mix(m, SourceView::interleaved(tap, 2), SourceView::interleaved(mic, 2), 1);
  CHECK(std::isfinite(s.l[0]));
  CHECK(std::fabs(s.l[0]) <= 1.0f);
  // Right: both overflow to -inf either way, which clips like any other overload.
  CHECK(s.r[0] == -1.0f);
}

TEST_CASE("output does not depend on how the stream is cut into blocks", "[mixer]") {
  constexpr std::size_t kFrames = 1000;
  const auto tapI = interleave(makePlanar(2, kFrames, 0.2f));
  const auto micI = interleave(makePlanar(1, kFrames, 0.9f));

  // Cuts the stream into `blocks`. When `withChanges` is set, parameters change at sample 100,
  // 300 and 500, so every cut list below must have a block boundary at those positions (the
  // engine applies new parameters at the start of a block). Ramps then run across later cuts.
  auto run = [&](const std::vector<std::size_t>& blocks, bool withChanges) {
    Mixer m;
    m.setAppGain(0.0f);  // start with a ramp in progress
    std::vector<float> out(kFrames * 2);
    std::size_t at = 0;
    for (std::size_t n : blocks) {
      if (withChanges) {
        if (at == 100) m.setAppGain(1.7f);
        if (at == 300) m.setMicMuted(true);
        if (at == 500) m.setMicMuted(false);
      }
      m.process(SourceView::interleaved(tapI.data() + at * 2, 2), SourceView::interleaved(micI.data() + at, 1),
                StereoOut::interleaved(out.data() + at * 2), n);
      at += n;
    }
    REQUIRE(at == kFrames);
    return out;
  };

  const auto steady = run({kFrames}, false);
  CHECK(steady == run({1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 392}, false));
  CHECK(steady == run({500, 500}, false));

  const auto changed = run({100, 100, 100, 100, 100, 100, 100, 100, 100, 100}, true);
  CHECK(changed == run({100, 200, 50, 50, 100, 100, 7, 93, 100, 200}, true));
  CHECK(changed == run({100, 200, 200, 500}, true));
  CHECK(changed != steady);
}

TEST_CASE("zero frames do nothing", "[mixer]") {
  Mixer m;
  float sentinel[2] = {7.0f, 7.0f};
  m.process(SourceView{}, SourceView{}, StereoOut::interleaved(sentinel), 0);
  CHECK(sentinel[0] == 7.0f);
  CHECK(sentinel[1] == 7.0f);
}
