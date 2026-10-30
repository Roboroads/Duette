// Real-time guard: counts calls to the global operator new while the real-time code runs.
//
// This file replaces the global allocation functions, which affects the whole executable, so it
// is built into its own test program (duette_core_alloc_tests) and not mixed into the others.
// It is compiled without optimization: an optimizer may legally delete a new/delete pair whose
// memory is never used, and that would hide a real allocation from the counter.

#include <duette/audio_view.hpp>
#include <duette/loopback_buffer.hpp>
#include <duette/meter.hpp>
#include <duette/mixer.hpp>
#include <duette/smoothed_gain.hpp>
#include <duette/tone.hpp>
#include <duette/zero_run.hpp>

#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <memory>
#include <new>
#include <vector>

namespace {

std::atomic<bool> g_armed{false};
std::atomic<std::size_t> g_calls{0};

void note() noexcept {
  if (g_armed.load(std::memory_order_relaxed)) g_calls.fetch_add(1, std::memory_order_relaxed);
}

void* allocate(std::size_t size) {
  note();
  void* p = std::malloc(size != 0 ? size : 1);
  if (p == nullptr) throw std::bad_alloc();
  return p;
}

void* allocateAligned(std::size_t size, std::size_t alignment) {
  note();
  if (alignment < sizeof(void*)) alignment = sizeof(void*);
  void* p = nullptr;
  if (posix_memalign(&p, alignment, size != 0 ? size : 1) != 0) throw std::bad_alloc();
  return p;
}

// Counts operator new calls from construction to `count()`.
class AllocScope {
 public:
  AllocScope() noexcept {
    g_calls.store(0, std::memory_order_relaxed);
    g_armed.store(true, std::memory_order_relaxed);
  }
  ~AllocScope() { g_armed.store(false, std::memory_order_relaxed); }
  AllocScope(const AllocScope&) = delete;
  AllocScope& operator=(const AllocScope&) = delete;
  std::size_t count() const noexcept { return g_calls.load(std::memory_order_relaxed); }
};

}  // namespace

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept {
  note();
  return std::malloc(size != 0 ? size : 1);
}
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept {
  note();
  return std::malloc(size != 0 ? size : 1);
}
void* operator new(std::size_t size, std::align_val_t alignment) {
  return allocateAligned(size, static_cast<std::size_t>(alignment));
}
void* operator new[](std::size_t size, std::align_val_t alignment) {
  return allocateAligned(size, static_cast<std::size_t>(alignment));
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete(void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }

namespace {

using duette::LoopbackBuffer;
using duette::Mixer;
using duette::PeakRmsMeter;
using duette::SmoothedGain;
using duette::SourceView;
using duette::StereoOut;
using duette::ToneGenerator;
using duette::ZeroRunDetector;

constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
constexpr float kInf = std::numeric_limits<float>::infinity();

}  // namespace

TEST_CASE("the guard sees allocations", "[alloc]") {
  // If this fails, every "allocates nothing" check below proves nothing.
  std::size_t calls = 0;
  {
    AllocScope scope;
    char* volatile p = new char[64];  // volatile: the allocation cannot be optimized away
    delete[] p;
    int* volatile q = new int(3);
    delete q;
    calls = scope.count();
  }
  CHECK(calls == 2);

  std::size_t quiet = 1;
  {
    AllocScope scope;
    quiet = scope.count();
  }
  CHECK(quiet == 0);
}

TEST_CASE("Mixer::process allocates nothing", "[alloc][mixer]") {
  constexpr std::size_t kFrames = 512;
  std::vector<float> tapInterleaved(kFrames * 2, 0.25f);
  std::vector<float> micInterleaved(kFrames * 4, -0.1f);
  std::vector<float> tapL(kFrames, 0.3f), tapR(kFrames, -0.3f);
  std::vector<float> mic0(kFrames, 0.2f), mic1(kFrames, 0.1f);
  std::vector<float> badTap(kFrames * 2, kNaN);
  badTap[3] = kInf;
  std::vector<float> outInterleaved(kFrames * 2);
  std::vector<float> outL(kFrames), outR(kFrames);
  const float* tapPlanes[2] = {tapL.data(), tapR.data()};
  const float* micPlanes[2] = {mic0.data(), mic1.data()};

  std::size_t calls = 0;
  {
    AllocScope scope;
    Mixer mixer(48000.0f);
    SourceView mixedMic;  // built from several buffers, as for an AudioBufferList
    mixedMic.appendInterleaved(micInterleaved.data(), 4);
    mixedMic.appendPlane(mic0.data());

    for (int round = 0; round < 4; ++round) {
      mixer.setAppGain(round % 2 == 0 ? 2.0f : 0.5f);  // ramps run through the blocks below
      mixer.setMicGain(1.5f);
      mixer.setAppMuted(round == 2);
      mixer.setMicMuted(round == 3);
      mixer.process(SourceView::interleaved(tapInterleaved.data(), 2),
                    SourceView::interleaved(micInterleaved.data(), 4),
                    StereoOut::interleaved(outInterleaved.data()), kFrames);
      mixer.process(SourceView::planar(tapPlanes, 2), SourceView::planar(micPlanes, 2),
                    StereoOut::planar(outL.data(), outR.data()), kFrames);
      mixer.process(SourceView::interleaved(badTap.data(), 2), mixedMic,
                    StereoOut::interleaved(outInterleaved.data()), kFrames);
      mixer.process(SourceView{}, SourceView{}, StereoOut::interleaved(outInterleaved.data()), kFrames);
      mixer.process(SourceView::interleaved(tapInterleaved.data(), 1), SourceView{},
                    StereoOut::interleaved(outInterleaved.data()), 1);
    }
    calls = scope.count();
  }
  CHECK(calls == 0);
}

TEST_CASE("LoopbackBuffer read and write allocate nothing", "[alloc][loopback]") {
  constexpr std::size_t kFrames = 480;
  auto buffer = std::make_unique<LoopbackBuffer<2, 16384>>();  // built before the guard is armed
  std::vector<float> block(kFrames * 2, 0.5f);
  std::vector<float> huge(20000 * 2, 0.25f);
  std::vector<float> out(kFrames * 2);

  std::size_t calls = 0;
  {
    AllocScope scope;
    std::int64_t t = 0;
    for (int i = 0; i < 100; ++i) {  // several wraps of the ring
      buffer->write(t, block.data(), kFrames);
      buffer->read(t - 100, out.data(), kFrames);       // partly stale or unwritten at first
      buffer->read(t + 100, out.data(), kFrames);       // partly past the end
      buffer->read(t, out.data(), kFrames);
      t += static_cast<std::int64_t>(kFrames);
    }
    buffer->write(t + 5000, block.data(), kFrames);    // writer restarts later
    buffer->read(t, out.data(), kFrames);
    buffer->write(100, block.data(), kFrames);          // writer goes back in time
    buffer->read(0, out.data(), kFrames);
    buffer->write(0, huge.data(), 20000);               // block longer than the capacity
    buffer->read(5000, out.data(), kFrames);
    static_cast<void>(buffer->lastWrittenEnd());
    calls = scope.count();
  }
  CHECK(calls == 0);
}

TEST_CASE("the remaining real-time classes allocate nothing", "[alloc]") {
  std::vector<float> samples(1024, 0.1f);
  std::vector<float> out(1024 * 2);
  const float* planes[2] = {samples.data(), samples.data()};

  std::size_t calls = 0;
  {
    AllocScope scope;

    SmoothedGain gain(48000.0f);
    for (int i = 0; i < 1000; ++i) {
      if (i % 300 == 0) gain.setGain(static_cast<float>(i % 3));
      if (i % 450 == 0) gain.setMuted(i % 900 == 0);
      static_cast<void>(gain.next());
    }

    PeakRmsMeter meter;
    meter.update(samples.data(), samples.size());
    meter.update(samples.data(), 512, 2);
    meter.update(SourceView::planar(planes, 2), 1024);

    ToneGenerator tone(48000.0f, 1000.0f, 0.5f);
    tone.fill(out.data(), 1024, 2);
    tone.setFrequency(440.0f);
    tone.fill(out.data(), 1024, 1);

    ZeroRunDetector zeros;
    zeros.update(samples.data(), 512, 2);
    zeros.update(SourceView::interleaved(samples.data(), 2), 512);
    static_cast<void>(zeros.zeroFrames());

    calls = scope.count();
  }
  CHECK(calls == 0);
}
