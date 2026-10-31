#include "DuetteDevices.hpp"

#include "Log.hpp"
#include "duette_driver_protocol.h"

#include <aspl/Client.hpp>
#include <aspl/Stream.hpp>

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <utility>

namespace duette::driver {

namespace {

// -12 dBFS peak.
const float kSelfTestToneAmplitude =
    static_cast<float>(std::pow(10.0, static_cast<double>(DUETTE_SELF_TEST_TONE_DBFS) / 20.0));

aspl::DeviceParameters duetteParameters() {
  aspl::DeviceParameters p;
  p.Name = DUETTE_DEVICE_NAME;
  p.Manufacturer = DUETTE_DRIVER_MANUFACTURER;
  p.DeviceUID = DUETTE_DEVICE_UID;
  p.ModelUID = DUETTE_DEVICE_UID ".model";
  p.SerialNumber = DUETTE_DEVICE_UID;
  p.FirmwareVersion = DUETTE_DRIVER_VERSION;
  p.CanBeDefault = true;
  p.CanBeDefaultForSystemSounds = false;
  p.SampleRate = static_cast<UInt32>(kSampleRate);
  p.ChannelCount = kChannels;
  p.Latency = 0;
  p.SafetyOffset = kInputSafetyOffset;
  p.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
  p.ClockIsStable = true;
  p.ClockDomain = DUETTE_CLOCK_DOMAIN;
  p.EnableMixing = true;
  p.EnableRealtimeTracing = false;
  return p;
}

aspl::DeviceParameters sinkParameters() {
  aspl::DeviceParameters p;
  p.Name = DUETTE_SINK_NAME;
  p.Manufacturer = DUETTE_DRIVER_MANUFACTURER;
  p.DeviceUID = DUETTE_SINK_UID;
  p.ModelUID = DUETTE_SINK_UID ".model";
  p.SerialNumber = DUETTE_SINK_UID;
  p.FirmwareVersion = DUETTE_DRIVER_VERSION;
  p.CanBeDefault = false;
  p.CanBeDefaultForSystemSounds = false;
  p.SampleRate = static_cast<UInt32>(kSampleRate);
  p.ChannelCount = kChannels;
  p.Latency = 0;
  p.SafetyOffset = 0;
  p.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
  p.ClockIsStable = true;
  p.ClockDomain = DUETTE_CLOCK_DOMAIN;
  // The HAL mixes the clients of one IO context, so WriteMix gets their sum. Separate IO contexts
  // (the app's aggregate and a direct client) each call WriteMix; LoopbackWriter sorts that out.
  p.EnableMixing = true;
  p.EnableRealtimeTracing = false;
  return p;
}

}  // namespace

// ------------------------------------------------------------------------------------- helpers

std::uint64_t machHostNow() noexcept { return mach_absolute_time(); }

HostTimebase machTimebase() noexcept {
  mach_timebase_info_data_t info{};
  if (mach_timebase_info(&info) != KERN_SUCCESS || info.numer == 0 || info.denom == 0) {
    return HostTimebase{1, 1};
  }
  return HostTimebase{info.numer, info.denom};
}

AudioStreamBasicDescription floatStreamFormat(double sampleRate, UInt32 channels) {
  AudioStreamBasicDescription f{};
  f.mSampleRate = sampleRate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
  f.mBitsPerChannel = 32;
  f.mChannelsPerFrame = channels;
  f.mBytesPerFrame = 4 * channels;
  f.mFramesPerPacket = 1;
  f.mBytesPerPacket = 4 * channels;
  return f;
}

DriverClock makeDriverClock() {
  DriverClock c;
  c.timebase = machTimebase();
  c.anchorHostTime = machHostNow();
  ClockConfig config;
  config.sampleRate = kSampleRate;
  config.periodFrames = kZeroTimeStampPeriod;
  c.main = std::make_shared<const SharedClock>(&machHostNow, c.timebase, c.anchorHostTime, config);
  return c;
}

// ------------------------------------------------------------------------------- ClockedDevice

ClockedDevice::ClockedDevice(std::shared_ptr<const aspl::Context> context,
                             const aspl::DeviceParameters& params,
                             std::shared_ptr<const SharedClock> clock)
    : aspl::Device(std::move(context), params), clock_(std::move(clock)) {}

OSStatus ClockedDevice::GetZeroTimeStamp(AudioObjectID objectID, UInt32 /*clientID*/,
                                         Float64* outSampleTime, UInt64* outHostTime,
                                         UInt64* outSeed) {
  if (objectID != GetID()) return kAudioHardwareBadObjectError;
  if (outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  const ZeroTimeStamp z = ioClock().now();
  *outSampleTime = z.sampleTime;
  *outHostTime = z.hostTime;
  *outSeed = z.seed;
  return kAudioHardwareNoError;
}

OSStatus ClockedDevice::WillDoIOOperation(AudioObjectID objectID, UInt32 /*clientID*/,
                                          UInt32 operationID, Boolean* outWillDo,
                                          Boolean* outWillDoInPlace) {
  if (objectID != GetID()) return kAudioHardwareBadObjectError;
  if (outWillDo == nullptr || outWillDoInPlace == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  *outWillDo = willDo(operationID) ? 1 : 0;
  *outWillDoInPlace = 1;
  return kAudioHardwareNoError;
}

OSStatus ClockedDevice::BeginIOOperation(AudioObjectID objectID, UInt32 /*clientID*/,
                                         UInt32 /*operationID*/, UInt32 /*ioBufferFrameSize*/,
                                         const AudioServerPlugInIOCycleInfo* /*ioCycleInfo*/) {
  return objectID == GetID() ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus ClockedDevice::DoIOOperation(AudioObjectID objectID, AudioObjectID /*streamID*/,
                                      UInt32 /*clientID*/, UInt32 operationID,
                                      UInt32 ioBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* ioCycleInfo,
                                      void* ioMainBuffer, void* /*ioSecondaryBuffer*/) {
  if (objectID != GetID()) return kAudioHardwareBadObjectError;
  if (ioCycleInfo == nullptr || ioMainBuffer == nullptr) return kAudioHardwareNoError;
  doIO(operationID, ioBufferFrameSize, *ioCycleInfo, ioMainBuffer);
  return kAudioHardwareNoError;
}

OSStatus ClockedDevice::EndIOOperation(AudioObjectID objectID, UInt32 /*clientID*/,
                                       UInt32 /*operationID*/, UInt32 /*ioBufferFrameSize*/,
                                       const AudioServerPlugInIOCycleInfo* /*ioCycleInfo*/) {
  return objectID == GetID() ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

pid_t ClockedDevice::clientPid(UInt32 clientID) const {
  const std::shared_ptr<aspl::Client> client = GetClientByID(clientID);
  return client ? client->GetProcessID() : -1;
}

std::int64_t ClockedDevice::wholeSampleTime(Float64 sampleTime) noexcept {
  return static_cast<std::int64_t>(std::floor(sampleTime + 0.5));
}

// --------------------------------------------------------------------------- DuetteInputDevice

DuetteInputDevice::DuetteInputDevice(std::shared_ptr<const aspl::Context> context,
                                     std::shared_ptr<const SharedClock> clock,
                                     std::shared_ptr<Loopback> loopback)
    : ClockedDevice(std::move(context), duetteParameters(), std::move(clock)),
      loopback_(std::move(loopback)),
      tone_(static_cast<std::uint32_t>(kSampleRate), DUETTE_SELF_TEST_TONE_HZ,
            kSelfTestToneAmplitude, kToneRampFrames) {
  // coreaudiod passes a plug-in's custom properties to clients only as CFString or
  // CFPropertyList, so both travel as CF objects (see duette_driver_protocol.h).
  RegisterCustomProperty(
      DUETTE_PROPERTY_SELF_TEST_TONE,
      std::function<CFPropertyListRef()>([this] { return copySelfTestToneValue(); }),
      std::function<void(CFPropertyListRef)>(
          [this](CFPropertyListRef value) { setSelfTestToneValue(value); }));
  RegisterCustomProperty(
      DUETTE_PROPERTY_INPUT_CLIENTS,
      std::function<CFPropertyListRef()>([this] { return copyInputClientsValue(); }),
      std::function<void(CFPropertyListRef)>{});
}

void DuetteInputDevice::setSelfTestTone(bool on) {
  // The fade starts at the device's current sample time; readers are a buffer or so behind that,
  // so they hear the old state until then and the fade after.
  const SharedClock& clock = ioClock();
  const auto now = static_cast<std::int64_t>(std::floor(clock.sampleTimeAt(clock.hostNow())));
  if (tone_.set(on, now)) {
    os_log_info(driverLog(), "Duette: self-test tone %{public}s", on ? "on" : "off");
    // So a UI shows the change when another client (duettectl) flips it.
    NotifyPropertyChanged(DUETTE_PROPERTY_SELF_TEST_TONE);
  }
}

CFPropertyListRef DuetteInputDevice::copySelfTestToneValue() const {
  const SInt32 value = selfTestTone() ? 1 : 0;
  return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
}

void DuetteInputDevice::setSelfTestToneValue(CFPropertyListRef value) {
  if (value == nullptr) return;
  const CFTypeID type = CFGetTypeID(value);
  if (type == CFNumberGetTypeID()) {
    SInt32 n = 0;
    if (CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &n)) {
      setSelfTestTone(n != 0);
    }
  } else if (type == CFBooleanGetTypeID()) {
    setSelfTestTone(CFBooleanGetValue(static_cast<CFBooleanRef>(value)));
  } else {
    os_log_error(driverLog(), "Duette: ignoring a self-test tone value of CF type %lu",
                 static_cast<unsigned long>(type));
  }
}

std::vector<pid_t> DuetteInputDevice::inputClientPids() const {
  std::vector<pid_t> pids;
  {
    std::lock_guard<std::mutex> lock(clientsMutex_);
    pids.reserve(ioClients_.size());
    for (const auto& entry : ioClients_) {
      if (entry.second > 0) pids.push_back(entry.second);
    }
  }
  std::sort(pids.begin(), pids.end());
  pids.erase(std::unique(pids.begin(), pids.end()), pids.end());
  return pids;
}

CFPropertyListRef DuetteInputDevice::copyInputClientsValue() const {
  const std::vector<pid_t> pids = inputClientPids();
  CFMutableArrayRef array =
      CFArrayCreateMutable(kCFAllocatorDefault, static_cast<CFIndex>(pids.size()), &kCFTypeArrayCallBacks);
  if (array == nullptr) return nullptr;
  for (const pid_t pid : pids) {
    const SInt32 value = static_cast<SInt32>(pid);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (number != nullptr) {
      CFArrayAppendValue(array, number);
      CFRelease(number);
    }
  }
  return array;
}

bool DuetteInputDevice::updateIoClient(UInt32 clientID, pid_t pid, bool running) {
  const std::vector<pid_t> before = inputClientPids();
  {
    std::lock_guard<std::mutex> lock(clientsMutex_);
    if (running) {
      ioClients_[clientID] = pid;
    } else {
      ioClients_.erase(clientID);
    }
  }
  return inputClientPids() != before;
}

OSStatus DuetteInputDevice::StartIOImpl(UInt32 clientID, UInt32 startCount) {
  const OSStatus status = ClockedDevice::StartIOImpl(clientID, startCount);
  if (status != kAudioHardwareNoError) return status;
  if (startCount == 0) {
    framesRead_.store(0, std::memory_order_relaxed);
    framesWithoutData_.store(0, std::memory_order_relaxed);
  }
  const pid_t pid = clientPid(clientID);
  const bool changed = updateIoClient(clientID, pid, true);
  os_log_info(driverLog(), "Duette: StartIO client %u pid %d, %u doing input IO",
              static_cast<unsigned>(clientID), static_cast<int>(pid),
              static_cast<unsigned>(startCount + 1));
  if (changed) NotifyPropertyChanged(DUETTE_PROPERTY_INPUT_CLIENTS);
  return kAudioHardwareNoError;
}

OSStatus DuetteInputDevice::StopIOImpl(UInt32 clientID, UInt32 startCount) {
  const OSStatus status = ClockedDevice::StopIOImpl(clientID, startCount);
  const bool changed = updateIoClient(clientID, -1, false);
  os_log_info(driverLog(), "Duette: StopIO client %u, %u still doing input IO",
              static_cast<unsigned>(clientID), static_cast<unsigned>(startCount));
  if (startCount == 0) {
    os_log_info(driverLog(),
                "Duette: input stopped; %llu frames read, %llu without sink data (underrun or "
                "no writer)",
                static_cast<unsigned long long>(framesRead_.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(framesWithoutData_.load(std::memory_order_relaxed)));
  }
  if (changed) NotifyPropertyChanged(DUETTE_PROPERTY_INPUT_CLIENTS);
  return status;
}

OSStatus DuetteInputDevice::RemoveClient(AudioObjectID objectID,
                                         const AudioServerPlugInClientInfo* rawClientInfo) {
  const OSStatus status = ClockedDevice::RemoveClient(objectID, rawClientInfo);
  // A client that goes away without StopIO (it crashed) must not stay in the list.
  if (rawClientInfo != nullptr && updateIoClient(rawClientInfo->mClientID, -1, false)) {
    os_log_info(driverLog(), "Duette: client %u removed while doing IO",
                static_cast<unsigned>(rawClientInfo->mClientID));
    NotifyPropertyChanged(DUETTE_PROPERTY_INPUT_CLIENTS);
  }
  return status;
}

bool DuetteInputDevice::willDo(UInt32 operationID) const noexcept {
  return operationID == kAudioServerPlugInIOOperationReadInput;
}

void DuetteInputDevice::doIO(UInt32 operationID, UInt32 frames,
                             const AudioServerPlugInIOCycleInfo& cycle, void* buffer) noexcept {
  if (operationID != kAudioServerPlugInIOOperationReadInput || frames == 0) return;
  auto* out = static_cast<float*>(buffer);
  const std::int64_t t = wholeSampleTime(cycle.mInputTime.mSampleTime);
  std::size_t missing = 0;
  // Several clients may read "Duette", from several IO threads; the tone keeps no per-call
  // state, so this is safe for all of them.
  tone_.render(t, out, frames, kChannels, [&](float* into, std::size_t n) {
    missing = n - loopback_->read(t, into, n);
  });
  framesRead_.fetch_add(frames, std::memory_order_relaxed);
  framesWithoutData_.fetch_add(missing, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------- DuetteSinkDevice

DuetteSinkDevice::DuetteSinkDevice(std::shared_ptr<const aspl::Context> context,
                                   std::shared_ptr<const SharedClock> clock,
                                   std::shared_ptr<Loopback> loopback)
    : ClockedDevice(std::move(context), sinkParameters(), std::move(clock)),
      loopback_(std::move(loopback)),
      writer_(*loopback_) {}

OSStatus DuetteSinkDevice::StartIOImpl(UInt32 clientID, UInt32 startCount) {
  const OSStatus status = ClockedDevice::StartIOImpl(clientID, startCount);
  if (status != kAudioHardwareNoError) return status;
  if (startCount == 0) framesWritten_.store(0, std::memory_order_relaxed);
  os_log_info(driverLog(), "Duette Sink: StartIO client %u pid %d, %u writers",
              static_cast<unsigned>(clientID), static_cast<int>(clientPid(clientID)),
              static_cast<unsigned>(startCount + 1));
  return kAudioHardwareNoError;
}

OSStatus DuetteSinkDevice::StopIOImpl(UInt32 clientID, UInt32 startCount) {
  const OSStatus status = ClockedDevice::StopIOImpl(clientID, startCount);
  os_log_info(driverLog(), "Duette Sink: StopIO client %u, %u writers left",
              static_cast<unsigned>(clientID), static_cast<unsigned>(startCount));
  if (startCount == 0) {
    const auto blocks = writer_.stats();
    os_log_info(driverLog(),
                "Duette Sink: output stopped; %llu frames written. Blocks since load: %llu "
                "written, %llu trimmed, %llu dropped as already written, %llu dropped while "
                "another IO context was writing",
                static_cast<unsigned long long>(framesWritten_.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(blocks.written),
                static_cast<unsigned long long>(blocks.trimmed),
                static_cast<unsigned long long>(blocks.droppedOverlap),
                static_cast<unsigned long long>(blocks.droppedBusy));
  }
  return status;
}

bool DuetteSinkDevice::willDo(UInt32 operationID) const noexcept {
  return operationID == kAudioServerPlugInIOOperationWriteMix;
}

void DuetteSinkDevice::doIO(UInt32 operationID, UInt32 frames,
                            const AudioServerPlugInIOCycleInfo& cycle, void* buffer) noexcept {
  if (operationID != kAudioServerPlugInIOOperationWriteMix || frames == 0) return;
  const std::int64_t t = wholeSampleTime(cycle.mOutputTime.mSampleTime);
  const LoopbackWriteResult r = writer_.write(t, static_cast<const float*>(buffer), frames);
  if (r == LoopbackWriteResult::Written || r == LoopbackWriteResult::Trimmed) {
    framesWritten_.fetch_add(frames, std::memory_order_relaxed);
  }
}

// --------------------------------------------------------------------------------- assembly

void addDuetteDevices(const std::shared_ptr<const aspl::Context>& context, aspl::Plugin& plugin,
                      const DriverClock& clock) {
  // 256 KiB: lives on the heap, made once at load.
  auto loopback = std::make_shared<Loopback>();

  auto input = std::make_shared<DuetteInputDevice>(context, clock.main, loopback);
  aspl::StreamParameters inputStream;
  inputStream.Direction = aspl::Direction::Input;
  inputStream.StartingChannel = 1;
  inputStream.Format = floatStreamFormat(kSampleRate);
  input->AddStreamAsync(inputStream);

  auto sink = std::make_shared<DuetteSinkDevice>(context, clock.main, loopback);
  aspl::StreamParameters sinkStream;
  sinkStream.Direction = aspl::Direction::Output;
  sinkStream.StartingChannel = 1;
  sinkStream.Format = floatStreamFormat(kSampleRate);
  sink->AddStreamAsync(sinkStream);

  plugin.AddDevice(input);
  plugin.AddDevice(sink);
}

}  // namespace duette::driver
