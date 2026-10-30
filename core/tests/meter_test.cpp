#include <duette/audio_view.hpp>
#include <duette/meter.hpp>

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cmath>
#include <cstddef>
#include <limits>
#include <thread>
#include <vector>

using duette::PeakRmsMeter;
using duette::SourceView;

namespace {

constexpr double kPi = 3.14159265358979323846;

std::vector<float> sine(double amplitude, double hz, std::size_t frames, double sampleRate = 48000.0) {
  std::vector<float> v(frames);
  for (std::size_t i = 0; i < frames; ++i) {
    v[i] = static_cast<float>(amplitude * std::sin(2.0 * kPi * hz * static_cast<double>(i) / sampleRate));
  }
  return v;
}

double dbDiff(double measured, double expected) { return 20.0 * std::log10(measured / expected); }

}  // namespace

TEST_CASE("a new meter reads silence", "[meter]") {
  PeakRmsMeter m;
  CHECK(m.peak() == 0.0f);
  CHECK(m.rms() == 0.0f);
}

TEST_CASE("peak and RMS of a known sine are within 0.1 dB", "[meter]") {
  for (double amplitude : {1.0, 0.5, 0.1, 0.001}) {
    for (double hz : {100.0, 997.0, 5000.0}) {
      const auto x = sine(amplitude, hz, 9600);  // whole-ish number of cycles, 200 ms
      PeakRmsMeter m;
      m.update(x.data(), x.size());
      INFO("amplitude " << amplitude << " at " << hz << " Hz");
      CHECK(std::fabs(dbDiff(static_cast<double>(m.peak()), amplitude)) < 0.1);
      CHECK(std::fabs(dbDiff(static_cast<double>(m.rms()), amplitude / std::sqrt(2.0))) < 0.1);
    }
  }
}

TEST_CASE("a block of a typical size is accurate too", "[meter]") {
  const auto x = sine(0.5, 1000.0, 480);  // 10 cycles, 10 ms
  PeakRmsMeter m;
  m.update(x.data(), x.size());
  CHECK(std::fabs(dbDiff(static_cast<double>(m.peak()), 0.5)) < 0.1);
  CHECK(std::fabs(dbDiff(static_cast<double>(m.rms()), 0.5 / std::sqrt(2.0))) < 0.1);
}

TEST_CASE("each update replaces the previous reading", "[meter]") {
  PeakRmsMeter m;
  const auto loud = sine(0.9, 1000.0, 480);
  m.update(loud.data(), loud.size());
  CHECK(m.peak() > 0.8f);

  const std::vector<float> quiet(480, 0.0f);
  m.update(quiet.data(), quiet.size());
  CHECK(m.peak() == 0.0f);
  CHECK(m.rms() == 0.0f);
}

TEST_CASE("an empty block leaves the reading alone", "[meter]") {
  PeakRmsMeter m;
  const std::vector<float> x(100, 0.5f);
  m.update(x.data(), x.size());
  m.update(x.data(), 0);
  m.update(nullptr, 0);
  CHECK(m.peak() == 0.5f);
  CHECK(m.rms() == Catch::Approx(0.5f));
}

TEST_CASE("negative samples count for the peak", "[meter]") {
  PeakRmsMeter m;
  const float x[4] = {0.1f, -0.7f, 0.3f, 0.2f};
  m.update(x, 4);
  CHECK(m.peak() == 0.7f);
}

TEST_CASE("interleaved channels are measured together", "[meter]") {
  // Left is a 0.8 sine, right is silent: peak is 0.8, RMS is over all samples of both channels.
  const auto l = sine(0.8, 1000.0, 480);
  std::vector<float> inter(l.size() * 2, 0.0f);
  for (std::size_t i = 0; i < l.size(); ++i) inter[2 * i] = l[i];

  PeakRmsMeter m;
  m.update(inter.data(), inter.size());
  CHECK(std::fabs(dbDiff(static_cast<double>(m.peak()), 0.8)) < 0.1);
  CHECK(std::fabs(dbDiff(static_cast<double>(m.rms()), 0.8 / std::sqrt(2.0) / std::sqrt(2.0))) < 0.1);
}

TEST_CASE("one channel of an interleaved buffer can be measured by stride", "[meter]") {
  const auto l = sine(0.8, 1000.0, 480);
  const auto r = sine(0.2, 1000.0, 480);
  std::vector<float> inter(l.size() * 2);
  for (std::size_t i = 0; i < l.size(); ++i) {
    inter[2 * i] = l[i];
    inter[2 * i + 1] = r[i];
  }

  PeakRmsMeter m;
  m.update(inter.data() + 1, l.size(), 2);  // right channel only
  CHECK(std::fabs(dbDiff(static_cast<double>(m.peak()), 0.2)) < 0.1);
}

TEST_CASE("a source view is measured over all its channels", "[meter]") {
  const auto a = sine(0.6, 440.0, 4800);
  const auto b = sine(0.3, 440.0, 4800);
  std::vector<float> inter(a.size() * 2);
  for (std::size_t i = 0; i < a.size(); ++i) {
    inter[2 * i] = a[i];
    inter[2 * i + 1] = b[i];
  }
  const float* planes[2] = {a.data(), b.data()};

  PeakRmsMeter fromInterleaved, fromPlanar, flat;
  fromInterleaved.update(SourceView::interleaved(inter.data(), 2), a.size());
  fromPlanar.update(SourceView::planar(planes, 2), a.size());
  flat.update(inter.data(), inter.size());

  CHECK(fromInterleaved.peak() == flat.peak());
  CHECK(fromPlanar.peak() == flat.peak());
  CHECK(fromInterleaved.rms() == Catch::Approx(flat.rms()).epsilon(1e-6));
  CHECK(fromPlanar.rms() == Catch::Approx(flat.rms()).epsilon(1e-6));
  CHECK(fromPlanar.peak() == Catch::Approx(0.6f).epsilon(0.001));

  PeakRmsMeter none;
  none.update(SourceView{}, 100);  // a missing source reads as silence
  CHECK(none.peak() == 0.0f);
  CHECK(none.rms() == 0.0f);
}

TEST_CASE("non-finite samples are ignored", "[meter]") {
  PeakRmsMeter m;
  const float x[4] = {std::numeric_limits<float>::quiet_NaN(), 0.5f,
                      std::numeric_limits<float>::infinity(), -0.25f};
  m.update(x, 4);
  CHECK(m.peak() == 0.5f);
  CHECK(std::isfinite(m.rms()));
  CHECK(m.rms() == Catch::Approx(std::sqrt((0.25 + 0.0625) / 4.0)).epsilon(1e-5));
}

TEST_CASE("a reader thread sees whole values while the audio thread updates", "[meter][threads]") {
  PeakRmsMeter m;
  std::atomic<bool> done{false};
  std::atomic<int> outOfRange{0};

  std::thread ui([&] {
    while (!done.load(std::memory_order_acquire)) {
      const float p = m.peak();
      const float r = m.rms();
      if (!(p >= 0.0f && p <= 1.0f && r >= 0.0f && r <= 1.0f)) ++outOfRange;
    }
  });

  const auto x = sine(0.9, 1000.0, 128);
  const std::vector<float> silence(128, 0.0f);
  for (int i = 0; i < 20000; ++i) {
    m.update(((i & 1) != 0 ? silence : x).data(), 128);
  }
  done.store(true, std::memory_order_release);
  ui.join();
  CHECK(outOfRange.load() == 0);
}
