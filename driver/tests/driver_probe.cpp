// duette-driver-probe: a CoreAudio client CI runs against the installed plug-in.
//
//   duette-driver-probe check         "Duette" and "Duette Sink": properties, custom properties,
//                                     self-test tone, input-client list, loopback, shared clock
//   duette-driver-probe test-devices  "Duette Test Mic" and "Duette Test Speaker"
//   duette-driver-probe absent        no Duette device is published (after uninstall)
//
// Prints one line per check ("PASS ...", "FAIL ...", "INFO ...") and exits 1 if any check fails.
// It is a test tool, not product code: it allocates and prints freely, but its IOProcs only copy
// samples.

#include "duette_driver_protocol.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace {

int gFailures = 0;

void report(bool ok, const char* name, const char* fmt, ...) __attribute__((format(printf, 3, 4)));
void report(bool ok, const char* name, const char* fmt, ...) {
  char detail[512];
  va_list args;
  va_start(args, fmt);
  std::vsnprintf(detail, sizeof detail, fmt, args);
  va_end(args);
  std::printf("%s %s: %s\n", ok ? "PASS" : "FAIL", name, detail);
  std::fflush(stdout);
  if (!ok) ++gFailures;
}

void info(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void info(const char* fmt, ...) {
  char detail[512];
  va_list args;
  va_start(args, fmt);
  std::vsnprintf(detail, sizeof detail, fmt, args);
  va_end(args);
  std::printf("INFO %s\n", detail);
  std::fflush(stdout);
}

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  return AudioObjectPropertyAddress{selector, scope, kAudioObjectPropertyElementMain};
}

std::string fourcc(OSStatus status) {
  const auto u = static_cast<UInt32>(status);
  char c[4] = {static_cast<char>(u >> 24), static_cast<char>(u >> 16), static_cast<char>(u >> 8),
               static_cast<char>(u)};
  bool printable = true;
  for (char ch : c) printable = printable && ch >= 32 && ch < 127;
  char buf[32];
  if (printable) {
    std::snprintf(buf, sizeof buf, "'%c%c%c%c'", c[0], c[1], c[2], c[3]);
  } else {
    std::snprintf(buf, sizeof buf, "%d", static_cast<int>(status));
  }
  return buf;
}

std::string toString(CFStringRef s) {
  if (s == nullptr) return {};
  char buf[512];
  if (!CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) return {};
  return buf;
}

AudioObjectID deviceForUID(const char* uid) {
  CFStringRef cfUID = CFStringCreateWithCString(kCFAllocatorDefault, uid, kCFStringEncodingUTF8);
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof device;
  const AudioObjectPropertyAddress a = address(kAudioHardwarePropertyTranslateUIDToDevice);
  const OSStatus s = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof cfUID, &cfUID,
                                                &size, &device);
  CFRelease(cfUID);
  return s == noErr ? device : kAudioObjectUnknown;
}

AudioObjectID waitForDevice(const char* uid, int seconds) {
  for (int i = 0; i < seconds * 4; ++i) {
    const AudioObjectID d = deviceForUID(uid);
    if (d != kAudioObjectUnknown) return d;
    sleepMs(250);
  }
  return kAudioObjectUnknown;
}

std::vector<AudioObjectID> deviceList() {
  const AudioObjectPropertyAddress a = address(kAudioHardwarePropertyDevices);
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) {
    return {};
  }
  std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) !=
      noErr) {
    return {};
  }
  ids.resize(size / sizeof(AudioObjectID));
  return ids;
}

bool listed(AudioObjectID device) {
  const auto ids = deviceList();
  return std::find(ids.begin(), ids.end(), device) != ids.end();
}

template <typename T>
bool get(AudioObjectID object, AudioObjectPropertySelector selector, T& out,
         AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, OSStatus* status = nullptr) {
  const AudioObjectPropertyAddress a = address(selector, scope);
  UInt32 size = sizeof(T);
  const OSStatus s = AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &out);
  if (status != nullptr) *status = s;
  return s == noErr && size == sizeof(T);
}

std::string stringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
  CFStringRef s = nullptr;
  if (!get(object, selector, s)) return {};
  std::string r = toString(s);
  if (s != nullptr) CFRelease(s);
  return r;
}

UInt32 uint32Property(AudioObjectID object, AudioObjectPropertySelector selector,
                      AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  UInt32 v = 0xFFFFFFFFu;
  get(object, selector, v, scope);
  return v;
}

UInt32 streamCount(AudioObjectID device, AudioObjectPropertyScope scope) {
  const AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreams, scope);
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) != noErr) return 0;
  return size / sizeof(AudioStreamID);
}

UInt32 channelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
  const AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreamConfiguration, scope);
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) != noErr || size == 0) return 0;
  std::vector<unsigned char> storage(size);
  auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
  if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, list) != noErr) return 0;
  UInt32 channels = 0;
  for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += list->mBuffers[i].mNumberChannels;
  return channels;
}

Float64 nominalRate(AudioObjectID device) {
  Float64 rate = 0;
  get(device, kAudioDevicePropertyNominalSampleRate, rate);
  return rate;
}

// ---- custom properties (CFPropertyList values) ----

bool getPlist(AudioObjectID device, AudioObjectPropertySelector selector, CFPropertyListRef& out,
              OSStatus& status) {
  out = nullptr;
  const AudioObjectPropertyAddress a = address(selector);
  UInt32 size = sizeof(CFPropertyListRef);
  status = AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, &out);
  return status == noErr && out != nullptr;
}

int selfTestTone(AudioObjectID device) {
  CFPropertyListRef v = nullptr;
  OSStatus s = noErr;
  if (!getPlist(device, DUETTE_PROPERTY_SELF_TEST_TONE, v, s)) return -1;
  int result = -2;
  if (CFGetTypeID(v) == CFNumberGetTypeID()) {
    SInt32 n = 0;
    if (CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberSInt32Type, &n)) result = n;
  }
  CFRelease(v);
  return result;
}

OSStatus setSelfTestTone(AudioObjectID device, bool on) {
  const SInt32 n = on ? 1 : 0;
  CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &n);
  const AudioObjectPropertyAddress a = address(DUETTE_PROPERTY_SELF_TEST_TONE);
  CFPropertyListRef plist = value;
  const OSStatus s = AudioObjectSetPropertyData(device, &a, 0, nullptr, sizeof plist, &plist);
  CFRelease(value);
  return s;
}

bool inputClients(AudioObjectID device, std::vector<pid_t>& pids, OSStatus& status) {
  pids.clear();
  CFPropertyListRef v = nullptr;
  if (!getPlist(device, DUETTE_PROPERTY_INPUT_CLIENTS, v, status)) return false;
  bool ok = CFGetTypeID(v) == CFArrayGetTypeID();
  if (ok) {
    auto array = static_cast<CFArrayRef>(v);
    for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
      auto n = static_cast<CFNumberRef>(CFArrayGetValueAtIndex(array, i));
      SInt32 pid = 0;
      if (CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue(n, kCFNumberSInt32Type, &pid)) {
        pids.push_back(static_cast<pid_t>(pid));
      } else {
        ok = false;
      }
    }
  }
  CFRelease(v);
  return ok;
}

bool contains(const std::vector<pid_t>& pids, pid_t pid) {
  return std::find(pids.begin(), pids.end(), pid) != pids.end();
}

std::string join(const std::vector<pid_t>& pids) {
  std::string s = "[";
  for (std::size_t i = 0; i < pids.size(); ++i) {
    if (i) s += ",";
    s += std::to_string(pids[i]);
  }
  return s + "]";
}

// ---- IO ----

struct Recorder {
  std::vector<float> samples;  // interleaved stereo
  std::atomic<std::size_t> frames{0};
  explicit Recorder(std::size_t capacityFrames) : samples(capacityFrames * 2, 0.0f) {}
};

OSStatus recordProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
                    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context) {
  auto* r = static_cast<Recorder*>(context);
  if (input == nullptr || input->mNumberBuffers == 0) return noErr;
  const AudioBuffer& b = input->mBuffers[0];
  if (b.mData == nullptr || b.mNumberChannels == 0) return noErr;
  const std::size_t frames = b.mDataByteSize / (sizeof(float) * b.mNumberChannels);
  const auto* in = static_cast<const float*>(b.mData);
  std::size_t at = r->frames.load(std::memory_order_relaxed);
  const std::size_t capacity = r->samples.size() / 2;
  for (std::size_t f = 0; f < frames && at < capacity; ++f, ++at) {
    r->samples[at * 2] = in[f * b.mNumberChannels];
    r->samples[at * 2 + 1] = in[f * b.mNumberChannels + (b.mNumberChannels > 1 ? 1 : 0)];
  }
  r->frames.store(at, std::memory_order_relaxed);
  return noErr;
}

struct Player {
  double phase = 0.0;
  double increment = 1000.0 / 48000.0;
  float amplitude = 0.5f;
};

OSStatus playProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*,
                  AudioBufferList* output, const AudioTimeStamp*, void* context) {
  auto* p = static_cast<Player*>(context);
  if (output == nullptr) return noErr;
  for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
    AudioBuffer& b = output->mBuffers[i];
    if (b.mData == nullptr || b.mNumberChannels == 0) continue;
    auto* out = static_cast<float*>(b.mData);
    const std::size_t frames = b.mDataByteSize / (sizeof(float) * b.mNumberChannels);
    double phase = p->phase;
    for (std::size_t f = 0; f < frames; ++f) {
      const auto s = static_cast<float>(p->amplitude * std::sin(2.0 * M_PI * phase));
      for (UInt32 c = 0; c < b.mNumberChannels; ++c) out[f * b.mNumberChannels + c] = s;
      phase += p->increment;
      if (phase >= 1.0) phase -= 1.0;
    }
    if (i + 1 == output->mNumberBuffers) p->phase = phase;
  }
  return noErr;
}

class IOProc {
 public:
  IOProc(AudioObjectID device, AudioDeviceIOProc proc, void* context) : device_(device) {
    status_ = AudioDeviceCreateIOProcID(device, proc, context, &id_);
  }
  ~IOProc() {
    stop();
    if (id_ != nullptr) AudioDeviceDestroyIOProcID(device_, id_);
  }
  OSStatus start() {
    if (status_ != noErr) return status_;
    status_ = AudioDeviceStart(device_, id_);
    started_ = status_ == noErr;
    return status_;
  }
  void stop() {
    if (started_) AudioDeviceStop(device_, id_);
    started_ = false;
  }
  OSStatus status() const { return status_; }

 private:
  AudioObjectID device_;
  AudioDeviceIOProcID id_ = nullptr;
  OSStatus status_ = noErr;
  bool started_ = false;
};

struct ToneStats {
  double frequency = 0;
  float peak = 0;
  std::size_t frames = 0;
  std::size_t nonZero = 0;
};

// Frequency from rising zero crossings on the left channel of the last `seconds` recorded.
ToneStats analyze(const Recorder& r, double sampleRate, double seconds) {
  ToneStats st;
  const std::size_t total = r.frames.load();
  const auto want = static_cast<std::size_t>(seconds * sampleRate);
  if (total < 2) return st;
  const std::size_t begin = total > want ? total - want : 0;
  st.frames = total - begin;
  std::size_t crossings = 0;
  std::size_t first = 0, last = 0;
  for (std::size_t f = begin; f < total; ++f) {
    const float x = r.samples[f * 2];
    st.peak = std::max(st.peak, std::fabs(x));
    if (x != 0.0f) ++st.nonZero;
    if (f > begin && r.samples[(f - 1) * 2] <= 0.0f && x > 0.0f) {
      if (crossings == 0) first = f;
      last = f;
      ++crossings;
    }
  }
  if (crossings >= 2 && last > first) {
    st.frequency = static_cast<double>(crossings - 1) * sampleRate / static_cast<double>(last - first);
  }
  return st;
}

bool waitUntil(int ms, const std::function<bool()>& condition) {
  for (int waited = 0; waited <= ms; waited += 50) {
    if (condition()) return true;
    sleepMs(50);
  }
  return condition();
}

std::atomic<int> gClientNotifications{0};

OSStatus clientsChanged(AudioObjectID, UInt32 count, const AudioObjectPropertyAddress* addresses,
                        void*) {
  for (UInt32 i = 0; i < count; ++i) {
    if (addresses[i].mSelector == DUETTE_PROPERTY_INPUT_CLIENTS) ++gClientNotifications;
  }
  return noErr;
}

// ---- commands ----

void checkDeviceBasics(AudioObjectID duette, AudioObjectID sink) {
  report(stringProperty(duette, kAudioObjectPropertyName) == DUETTE_DEVICE_NAME, "duette.name",
         "'%s'", stringProperty(duette, kAudioObjectPropertyName).c_str());
  report(stringProperty(sink, kAudioObjectPropertyName) == DUETTE_SINK_NAME, "sink.name", "'%s'",
         stringProperty(sink, kAudioObjectPropertyName).c_str());
  report(stringProperty(duette, kAudioObjectPropertyManufacturer) == DUETTE_DRIVER_MANUFACTURER,
         "duette.manufacturer", "'%s'",
         stringProperty(duette, kAudioObjectPropertyManufacturer).c_str());

  report(listed(duette), "duette.listed", "in kAudioHardwarePropertyDevices: %d", listed(duette));
  report(!listed(sink), "sink.not-listed", "in kAudioHardwarePropertyDevices: %d", listed(sink));
  report(uint32Property(duette, kAudioDevicePropertyIsHidden) == 0, "duette.visible",
         "IsHidden=%u", uint32Property(duette, kAudioDevicePropertyIsHidden));
  report(uint32Property(sink, kAudioDevicePropertyIsHidden) == 1, "sink.hidden", "IsHidden=%u",
         uint32Property(sink, kAudioDevicePropertyIsHidden));

  const UInt32 duetteDefault =
      uint32Property(duette, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput);
  report(duetteDefault == 1, "duette.can-be-default", "%u", duetteDefault);
  const UInt32 sinkDefault =
      uint32Property(sink, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput);
  const UInt32 sinkSystem = uint32Property(sink, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                                           kAudioObjectPropertyScopeOutput);
  report(sinkDefault == 0 && sinkSystem == 0, "sink.not-default", "CanBeDefault=%u system=%u",
         sinkDefault, sinkSystem);

  report(streamCount(duette, kAudioObjectPropertyScopeInput) == 1 &&
             streamCount(duette, kAudioObjectPropertyScopeOutput) == 0,
         "duette.streams", "input=%u output=%u", streamCount(duette, kAudioObjectPropertyScopeInput),
         streamCount(duette, kAudioObjectPropertyScopeOutput));
  report(streamCount(sink, kAudioObjectPropertyScopeOutput) == 1 &&
             streamCount(sink, kAudioObjectPropertyScopeInput) == 0,
         "sink.streams", "input=%u output=%u", streamCount(sink, kAudioObjectPropertyScopeInput),
         streamCount(sink, kAudioObjectPropertyScopeOutput));
  report(channelCount(duette, kAudioObjectPropertyScopeInput) == DUETTE_CHANNEL_COUNT,
         "duette.channels", "%u", channelCount(duette, kAudioObjectPropertyScopeInput));
  report(channelCount(sink, kAudioObjectPropertyScopeOutput) == DUETTE_CHANNEL_COUNT,
         "sink.channels", "%u", channelCount(sink, kAudioObjectPropertyScopeOutput));
  report(nominalRate(duette) == DUETTE_SAMPLE_RATE && nominalRate(sink) == DUETTE_SAMPLE_RATE,
         "rates", "duette=%.0f sink=%.0f", nominalRate(duette), nominalRate(sink));

  const UInt32 domainA = uint32Property(duette, kAudioDevicePropertyClockDomain);
  const UInt32 domainB = uint32Property(sink, kAudioDevicePropertyClockDomain);
  report(domainA == DUETTE_CLOCK_DOMAIN && domainB == DUETTE_CLOCK_DOMAIN, "clock-domain",
         "duette=0x%08x sink=0x%08x", domainA, domainB);
  const UInt32 periodA = uint32Property(duette, kAudioDevicePropertyZeroTimeStampPeriod);
  const UInt32 periodB = uint32Property(sink, kAudioDevicePropertyZeroTimeStampPeriod);
  report(periodA == periodB && periodA > 0, "zero-timestamp-period", "duette=%u sink=%u", periodA,
         periodB);
  info("latency duette=%u sink=%u, safety offset duette=%u sink=%u",
       uint32Property(duette, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
       uint32Property(sink, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
       uint32Property(duette, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
       uint32Property(sink, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput));
}

void checkCustomPropertyInfo(AudioObjectID duette) {
  const AudioObjectPropertyAddress a = address(kAudioObjectPropertyCustomPropertyInfoList);
  UInt32 size = 0;
  OSStatus s = AudioObjectGetPropertyDataSize(duette, &a, 0, nullptr, &size);
  std::vector<AudioServerPlugInCustomPropertyInfo> list(size / sizeof(AudioServerPlugInCustomPropertyInfo));
  if (s == noErr && size > 0) s = AudioObjectGetPropertyData(duette, &a, 0, nullptr, &size, list.data());
  std::string found;
  for (const auto& p : list) {
    char line[64];
    std::snprintf(line, sizeof line, "%s:%s ", fourcc(static_cast<OSStatus>(p.mSelector)).c_str(),
                  fourcc(static_cast<OSStatus>(p.mPropertyDataType)).c_str());
    found += line;
  }
  info("custom property info list: status=%s entries=%zu %s", fourcc(s).c_str(), list.size(),
       found.c_str());
}

void checkRawExperiment(AudioObjectID duette) {
  const AudioObjectPropertyAddress a = address(0x64787277u);  // 'dxrw'
  const Boolean has = AudioObjectHasProperty(duette, &a);
  UInt32 value = 0;
  UInt32 size = sizeof value;
  const OSStatus s = AudioObjectGetPropertyData(duette, &a, 0, nullptr, &size, &value);
  info("raw custom property experiment ('dxrw', UInt32, not in the info list): has=%d status=%s "
       "size=%u value=0x%08x (0x00c0ffee means raw values reach clients)",
       has, fourcc(s).c_str(), size, value);
}

int commandCheck() {
  const AudioObjectID duette = waitForDevice(DUETTE_DEVICE_UID, 30);
  report(duette != kAudioObjectUnknown, "duette.present", "id=%u", duette);
  const AudioObjectID sink = waitForDevice(DUETTE_SINK_UID, 10);
  report(sink != kAudioObjectUnknown, "sink.present", "id=%u (found by UID)", sink);
  if (duette == kAudioObjectUnknown || sink == kAudioObjectUnknown) return 1;

  checkDeviceBasics(duette, sink);
  checkCustomPropertyInfo(duette);
  checkRawExperiment(duette);

  // 'dtst'
  const int initial = selfTestTone(duette);
  report(initial == 0, "dtst.default-off", "value=%d", initial);
  const OSStatus setOn = setSelfTestTone(duette, true);
  report(setOn == noErr && selfTestTone(duette) == 1, "dtst.set-on", "status=%s value=%d",
         fourcc(setOn).c_str(), selfTestTone(duette));

  // 'dcli' and the tone, while this process reads "Duette".
  const AudioObjectPropertyAddress clientsAddress = address(DUETTE_PROPERTY_INPUT_CLIENTS);
  AudioObjectAddPropertyListener(duette, &clientsAddress, clientsChanged, nullptr);
  std::vector<pid_t> pids;
  OSStatus s = noErr;
  const bool readable = inputClients(duette, pids, s);
  report(readable && !contains(pids, getpid()), "dcli.idle", "status=%s pids=%s",
         fourcc(s).c_str(), join(pids).c_str());

  {
    Recorder rec(48000 * 3);
    IOProc in(duette, recordProc, &rec);
    const OSStatus started = in.start();
    report(started == noErr, "duette.start-io", "status=%s", fourcc(started).c_str());
    if (started == noErr) {
      const bool listedSelf = waitUntil(2000, [&] {
        return inputClients(duette, pids, s) && contains(pids, getpid());
      });
      report(listedSelf, "dcli.lists-reader", "own pid %d in %s", static_cast<int>(getpid()),
             join(pids).c_str());
      waitUntil(3000, [&] { return rec.frames.load() >= 48000; });
      sleepMs(300);
      const ToneStats st = analyze(rec, 48000.0, 0.5);
      const double expectedPeak = std::pow(10.0, DUETTE_SELF_TEST_TONE_DBFS / 20.0);
      report(std::fabs(st.frequency - DUETTE_SELF_TEST_TONE_HZ) <= 2.0 &&
                 std::fabs(st.peak - expectedPeak) <= 0.01,
             "dtst.tone", "%.2f Hz peak %.4f (want %d Hz, %.4f) over %zu frames",
             st.frequency, static_cast<double>(st.peak), DUETTE_SELF_TEST_TONE_HZ, expectedPeak,
             st.frames);
    }
    in.stop();
    const bool cleared = waitUntil(2000, [&] {
      return inputClients(duette, pids, s) && !contains(pids, getpid());
    });
    report(cleared, "dcli.clears-on-stop", "pids=%s", join(pids).c_str());
  }
  sleepMs(300);
  report(gClientNotifications.load() >= 2, "dcli.notifies", "%d property-changed notifications",
         gClientNotifications.load());
  AudioObjectRemovePropertyListener(duette, &clientsAddress, clientsChanged, nullptr);

  const OSStatus setOff = setSelfTestTone(duette, false);
  report(setOff == noErr && selfTestTone(duette) == 0, "dtst.set-off", "status=%s value=%d",
         fourcc(setOff).c_str(), selfTestTone(duette));

  // Loopback: play 1 kHz into the hidden sink, read it back from "Duette".
  {
    Player player;
    Recorder rec(48000 * 4);
    IOProc out(sink, playProc, &player);
    IOProc in(duette, recordProc, &rec);
    const OSStatus outStarted = out.start();
    const OSStatus inStarted = in.start();
    report(outStarted == noErr && inStarted == noErr, "loopback.start-io", "sink=%s duette=%s",
           fourcc(outStarted).c_str(), fourcc(inStarted).c_str());
    if (outStarted == noErr && inStarted == noErr) {
      waitUntil(4000, [&] { return rec.frames.load() >= 48000 * 2; });

      // Shared clock: both devices are at the same sample time at the same moment.
      double worst = 0;
      for (int i = 0; i < 10; ++i) {
        AudioTimeStamp a{}, b{};
        a.mFlags = b.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
        const OSStatus sa = AudioDeviceGetCurrentTime(duette, &a);
        const OSStatus sb = AudioDeviceGetCurrentTime(sink, &b);
        if (sa != noErr || sb != noErr) {
          worst = 1e9;
          break;
        }
        worst = std::max(worst, std::fabs(a.mSampleTime - b.mSampleTime));
        if (i == 0) info("current sample time duette=%.0f sink=%.0f", a.mSampleTime, b.mSampleTime);
        sleepMs(50);
      }
      report(worst < 64.0, "shared-clock", "largest sample-time difference %.1f frames", worst);
      Float64 rateA = 0, rateB = 0;
      get(duette, kAudioDevicePropertyActualSampleRate, rateA);
      get(sink, kAudioDevicePropertyActualSampleRate, rateB);
      info("actual sample rate duette=%.3f sink=%.3f", rateA, rateB);

      const ToneStats st = analyze(rec, 48000.0, 0.5);
      report(std::fabs(st.frequency - 1000.0) <= 3.0 && std::fabs(st.peak - 0.5f) <= 0.02f &&
                 st.nonZero > st.frames / 2,
             "loopback.tone", "%.2f Hz peak %.4f, %zu/%zu frames non-zero (want 1000 Hz, 0.5)",
             st.frequency, static_cast<double>(st.peak), st.nonZero, st.frames);
    }
    in.stop();
    out.stop();
  }

  // With no writer, "Duette" reads silence, not stale audio.
  {
    Recorder rec(48000 * 2);
    IOProc in(duette, recordProc, &rec);
    if (in.start() == noErr) {
      waitUntil(3000, [&] { return rec.frames.load() >= 48000; });
      const ToneStats st = analyze(rec, 48000.0, 0.5);
      report(st.peak == 0.0f && st.frames > 0, "silence-without-writer", "peak %.6f over %zu frames",
             static_cast<double>(st.peak), st.frames);
    } else {
      report(false, "silence-without-writer", "could not start IO");
    }
  }
  return gFailures == 0 ? 0 : 1;
}

int commandTestDevices() {
  const AudioObjectID mic = waitForDevice(DUETTE_TEST_MIC_UID, 30);
  const AudioObjectID speaker = waitForDevice(DUETTE_TEST_SPEAKER_UID, 10);
  const AudioObjectID duette = waitForDevice(DUETTE_DEVICE_UID, 10);
  report(mic != kAudioObjectUnknown && listed(mic), "test-mic.present", "id=%u listed=%d", mic,
         mic != kAudioObjectUnknown && listed(mic));
  report(speaker != kAudioObjectUnknown && listed(speaker), "test-speaker.present",
         "id=%u listed=%d", speaker, speaker != kAudioObjectUnknown && listed(speaker));
  if (mic == kAudioObjectUnknown || speaker == kAudioObjectUnknown || duette == kAudioObjectUnknown) {
    return 1;
  }
  report(stringProperty(mic, kAudioObjectPropertyName) == DUETTE_TEST_MIC_NAME, "test-mic.name",
         "'%s'", stringProperty(mic, kAudioObjectPropertyName).c_str());
  report(stringProperty(speaker, kAudioObjectPropertyName) == DUETTE_TEST_SPEAKER_NAME,
         "test-speaker.name", "'%s'", stringProperty(speaker, kAudioObjectPropertyName).c_str());
  report(uint32Property(mic, kAudioDevicePropertyClockDomain) != DUETTE_CLOCK_DOMAIN,
         "test-mic.own-clock-domain", "0x%08x", uint32Property(mic, kAudioDevicePropertyClockDomain));

  {
    Recorder rec(48000 * 6);
    Recorder ref(48000 * 6);
    IOProc in(mic, recordProc, &rec);
    IOProc base(duette, recordProc, &ref);
    const OSStatus started = in.start();
    base.start();
    report(started == noErr, "test-mic.start-io", "status=%s", fourcc(started).c_str());
    if (started == noErr) {
      waitUntil(3000, [&] { return rec.frames.load() >= 48000; });
      const ToneStats st = analyze(rec, 48000.0, 0.5);
      report(std::fabs(st.frequency - DUETTE_TEST_MIC_TONE_HZ) <= 3.0 && st.peak > 0.2f &&
                 st.peak < 0.3f,
             "test-mic.tone", "%.2f Hz peak %.4f", st.frequency, static_cast<double>(st.peak));

      // Drift against "Duette" (the shared clock) over a few seconds.
      AudioTimeStamp m0{}, d0{}, m1{}, d1{};
      m0.mFlags = d0.mFlags = m1.mFlags = d1.mFlags = kAudioTimeStampSampleTimeValid;
      AudioDeviceGetCurrentTime(mic, &m0);
      AudioDeviceGetCurrentTime(duette, &d0);
      sleepMs(4000);
      AudioDeviceGetCurrentTime(mic, &m1);
      AudioDeviceGetCurrentTime(duette, &d1);
      const double micFrames = m1.mSampleTime - m0.mSampleTime;
      const double duetteFrames = d1.mSampleTime - d0.mSampleTime;
      const double ppm = duetteFrames > 0 ? (micFrames / duetteFrames - 1.0) * 1e6 : 0.0;
      Float64 rate = 0;
      get(mic, kAudioDevicePropertyActualSampleRate, rate);
      info("test mic: %.0f frames vs %.0f on Duette over 4 s = %+.1f ppm; actual rate %.3f",
           micFrames, duetteFrames, ppm, rate);
      report(ppm > 100.0 && ppm < 300.0, "test-mic.drift", "%+.1f ppm (want about +%d)", ppm,
             DUETTE_TEST_MIC_CLOCK_PPM);
    }
  }

  // The speaker switches between 48 kHz and 44.1 kHz.
  const AudioObjectPropertyAddress ratesAddress = address(kAudioDevicePropertyAvailableNominalSampleRates);
  UInt32 size = 0;
  AudioObjectGetPropertyDataSize(speaker, &ratesAddress, 0, nullptr, &size);
  std::vector<AudioValueRange> rates(size / sizeof(AudioValueRange));
  if (!rates.empty()) AudioObjectGetPropertyData(speaker, &ratesAddress, 0, nullptr, &size, rates.data());
  bool has44 = false, has48 = false;
  for (const auto& r : rates) {
    has44 = has44 || (r.mMinimum <= 44100.0 && r.mMaximum >= 44100.0);
    has48 = has48 || (r.mMinimum <= 48000.0 && r.mMaximum >= 48000.0);
  }
  report(has44 && has48, "test-speaker.rates", "%zu ranges, 44.1k=%d 48k=%d", rates.size(), has44,
         has48);
  for (const Float64 want : {44100.0, 48000.0}) {
    const AudioObjectPropertyAddress a = address(kAudioDevicePropertyNominalSampleRate);
    const OSStatus s = AudioObjectSetPropertyData(speaker, &a, 0, nullptr, sizeof want, &want);
    const bool ok = waitUntil(3000, [&] { return nominalRate(speaker) == want; });
    report(s == noErr && ok, want == 44100.0 ? "test-speaker.set-44k" : "test-speaker.set-48k",
           "status=%s rate=%.0f", fourcc(s).c_str(), nominalRate(speaker));
  }
  return gFailures == 0 ? 0 : 1;
}

int commandAbsent() {
  sleepMs(2000);
  const AudioObjectID duette = deviceForUID(DUETTE_DEVICE_UID);
  const AudioObjectID sink = deviceForUID(DUETTE_SINK_UID);
  report(duette == kAudioObjectUnknown && sink == kAudioObjectUnknown, "absent",
         "duette=%u sink=%u", duette, sink);
  return gFailures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string command = argc > 1 ? argv[1] : "";
  if (command == "check") return commandCheck();
  if (command == "test-devices") return commandTestDevices();
  if (command == "absent") return commandAbsent();
  std::fprintf(stderr, "usage: %s check|test-devices|absent\n", argv[0]);
  return 2;
}
