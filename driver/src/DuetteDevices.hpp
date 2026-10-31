#pragma once

// The plug-in's devices. "Duette" (visible input) and "Duette Sink" (hidden output) share one
// clock and one LoopbackBuffer: whatever a client writes to the sink at sample time t, a reader
// of "Duette" gets back at sample time t.

#include "LoopbackWriter.hpp"
#include "SelfTestTone.hpp"
#include "SharedClock.hpp"

#include <aspl/Context.hpp>
#include <aspl/Device.hpp>
#include <aspl/Plugin.hpp>
#include <duette/loopback_buffer.hpp>
#include <duette/smoothed_gain.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace duette::driver {

inline constexpr double kSampleRate = 48000.0;
inline constexpr UInt32 kChannels = 2;
inline constexpr UInt32 kZeroTimeStampPeriod = 16384;
inline constexpr std::size_t kLoopbackFrames = 16384;
/// How far behind "now" the input reads. Covers a sink write cycle that runs a little late.
inline constexpr UInt32 kInputSafetyOffset = 16;
/// How far ahead of "now" the sink's writers must be. With 0 the HAL has no margin at all, and
/// any IO thread that wakes a little late is an overload ("safety violation"); seen in CI.
inline constexpr UInt32 kOutputSafetyOffset = 16;
/// Fade of the self-test tone: as long as SmoothedGain's ramps (5 ms, 240 frames).
inline constexpr UInt32 kToneRampFrames = static_cast<UInt32>(
    kSampleRate * static_cast<double>(duette::SmoothedGain::kDefaultRampSeconds) + 0.5);

using Loopback = duette::LoopbackBuffer<kChannels, kLoopbackFrames>;

/// mach_absolute_time as a HostTimeFn.
std::uint64_t machHostNow() noexcept;
/// mach_timebase_info as a HostTimebase.
HostTimebase machTimebase() noexcept;

/// 2-channel float32 interleaved stream format at `sampleRate`.
AudioStreamBasicDescription floatStreamFormat(double sampleRate, UInt32 channels = kChannels);

/// An aspl::Device driven by a SharedClock, whose real-time entry points take no locks.
///
/// libASPL's Device serializes GetZeroTimeStamp and the IO operations with StartIO/StopIO through
/// one mutex, and StartIO holds it while it traces. A second client starting IO could then block
/// the IO thread of the first. Our IO state is only atomics and the lock-free LoopbackBuffer, and
/// the clock is a pure function of host time, so the overrides below skip that mutex. Subclasses
/// say which operations they do and handle them in doIO(), on the IO thread: no allocation,
/// locks, logging or blocking calls there.
class ClockedDevice : public aspl::Device {
 public:
  ClockedDevice(std::shared_ptr<const aspl::Context> context, const aspl::DeviceParameters& params,
                std::shared_ptr<const SharedClock> clock);

  OSStatus GetZeroTimeStamp(AudioObjectID objectID, UInt32 clientID, Float64* outSampleTime,
                            UInt64* outHostTime, UInt64* outSeed) override;
  OSStatus WillDoIOOperation(AudioObjectID objectID, UInt32 clientID, UInt32 operationID,
                             Boolean* outWillDo, Boolean* outWillDoInPlace) override;
  OSStatus BeginIOOperation(AudioObjectID objectID, UInt32 clientID, UInt32 operationID,
                            UInt32 ioBufferFrameSize,
                            const AudioServerPlugInIOCycleInfo* ioCycleInfo) override;
  OSStatus DoIOOperation(AudioObjectID objectID, AudioObjectID streamID, UInt32 clientID,
                         UInt32 operationID, UInt32 ioBufferFrameSize,
                         const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer,
                         void* ioSecondaryBuffer) override;
  OSStatus EndIOOperation(AudioObjectID objectID, UInt32 clientID, UInt32 operationID,
                          UInt32 ioBufferFrameSize,
                          const AudioServerPlugInIOCycleInfo* ioCycleInfo) override;

 protected:
  /// The clock to report. The test speaker switches clocks with its sample rate.
  virtual const SharedClock& ioClock() const noexcept { return *clock_; }
  /// Whether this device takes part in `operationID` (always in place).
  virtual bool willDo(UInt32 operationID) const noexcept = 0;
  /// One IO operation for the device's only stream. `buffer` is float32 interleaved.
  virtual void doIO(UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo& cycle,
                    void* buffer) noexcept = 0;

  /// The PID of a client libASPL knows about, or -1.
  pid_t clientPid(UInt32 clientID) const;

  static std::int64_t wholeSampleTime(Float64 sampleTime) noexcept;

 private:
  std::shared_ptr<const SharedClock> clock_;
};

/// "Duette": the visible input. Plays back the sink's audio, or the self-test tone.
class DuetteInputDevice final : public ClockedDevice {
 public:
  DuetteInputDevice(std::shared_ptr<const aspl::Context> context,
                    std::shared_ptr<const SharedClock> clock, std::shared_ptr<Loopback> loopback);

  /// Self-test tone on or off ('dtst').
  bool selfTestTone() const noexcept { return tone_.on(); }
  void setSelfTestTone(bool on);

  /// PIDs of the clients doing input IO now ('dcli'), sorted, unique.
  std::vector<pid_t> inputClientPids() const;

  OSStatus RemoveClient(AudioObjectID objectID,
                        const AudioServerPlugInClientInfo* rawClientInfo) override;

 protected:
  OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override;
  OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override;
  bool willDo(UInt32 operationID) const noexcept override;
  void doIO(UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo& cycle,
            void* buffer) noexcept override;

 private:
  CFPropertyListRef copySelfTestToneValue() const;
  void setSelfTestToneValue(CFPropertyListRef value);
  CFPropertyListRef copyInputClientsValue() const;
  /// Records that `clientID` started (pid >= 0) or stopped (pid < 0) IO. Returns whether the
  /// published PID set changed.
  bool updateIoClient(UInt32 clientID, pid_t pid, bool running);

  std::shared_ptr<Loopback> loopback_;
  SelfTestTone tone_;

  // Kept on the IO thread, read off it (logged on StopIO).
  std::atomic<std::uint64_t> framesRead_{0};
  std::atomic<std::uint64_t> framesWithoutData_{0};

  mutable std::mutex clientsMutex_;
  std::map<UInt32, pid_t> ioClients_;  // client ID -> PID, for clients between StartIO and StopIO
};

/// "Duette Sink": the hidden output the app's aggregate writes the mix to.
class DuetteSinkDevice final : public ClockedDevice {
 public:
  DuetteSinkDevice(std::shared_ptr<const aspl::Context> context,
                   std::shared_ptr<const SharedClock> clock, std::shared_ptr<Loopback> loopback);

  /// Hidden from device lists: only Duette's own aggregate should use it. libASPL also has
  /// SetIsHidden(); overriding the getter keeps it hidden whatever calls that.
  bool GetIsHidden() const override { return true; }

 protected:
  OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override;
  OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override;
  bool willDo(UInt32 operationID) const noexcept override;
  void doIO(UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo& cycle,
            void* buffer) noexcept override;

 private:
  std::shared_ptr<Loopback> loopback_;
  LoopbackWriter<Loopback> writer_;  // after loopback_: it refers to it
  std::atomic<std::uint64_t> framesWritten_{0};
};

/// Everything the devices share, made once when coreaudiod loads the plug-in.
struct DriverClock {
  HostTimebase timebase;
  std::uint64_t anchorHostTime = 0;
  std::shared_ptr<const SharedClock> main;  // 48 kHz, shared by "Duette" and "Duette Sink"
};

DriverClock makeDriverClock();

/// Adds "Duette" and "Duette Sink" to `plugin`.
void addDuetteDevices(const std::shared_ptr<const aspl::Context>& context, aspl::Plugin& plugin,
                      const DriverClock& clock);

#if DUETTE_TEST_DEVICES
/// Adds "Duette Test Mic" and "Duette Test Speaker" (CI builds only).
void addTestDevices(const std::shared_ptr<const aspl::Context>& context, aspl::Plugin& plugin,
                    const DriverClock& clock);
#endif

}  // namespace duette::driver
