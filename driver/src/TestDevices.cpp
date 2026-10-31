// CI-only devices, compiled in with -DDUETTE_TEST_DEVICES=ON. A shipped plug-in never has them.
//
//   "Duette Test Mic":     input playing a 1 kHz tone on a clock that runs +200 ppm fast, so an
//                          aggregate with "Duette Sink" as its clock has drift to correct.
//   "Duette Test Speaker": visible output at 48 kHz or 44.1 kHz that discards what it gets; afplay
//                          plays into it so a process tap has something to tap.

#include "DuetteDevices.hpp"
#include "Log.hpp"
#include "duette_driver_protocol.h"

#include <aspl/Stream.hpp>

#include <cmath>
#include <utility>

namespace duette::driver {

namespace {

const float kTestToneAmplitude = static_cast<float>(std::pow(10.0, -12.0 / 20.0));  // -12 dBFS

class TestMicDevice final : public ClockedDevice {
 public:
  TestMicDevice(std::shared_ptr<const aspl::Context> context, std::shared_ptr<const SharedClock> clock)
      : ClockedDevice(std::move(context), parameters(), std::move(clock)) {}

 protected:
  bool willDo(UInt32 operationID) const noexcept override {
    return operationID == kAudioServerPlugInIOOperationReadInput;
  }

  void doIO(UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo& cycle,
            void* buffer) noexcept override {
    if (operationID != kAudioServerPlugInIOOperationReadInput || frames == 0) return;
    // A pure function of sample time, like the self-test tone: safe for any number of readers.
    const std::int64_t t = wholeSampleTime(cycle.mInputTime.mSampleTime);
    auto* out = static_cast<float*>(buffer);
    for (UInt32 i = 0; i < frames; ++i) {
      const float x = toneSample(t + static_cast<std::int64_t>(i),
                                 static_cast<std::uint32_t>(kSampleRate), DUETTE_TEST_MIC_TONE_HZ,
                                 kTestToneAmplitude);
      for (UInt32 c = 0; c < kChannels; ++c) out[i * kChannels + c] = x;
    }
  }

 private:
  static aspl::DeviceParameters parameters() {
    aspl::DeviceParameters p;
    p.Name = DUETTE_TEST_MIC_NAME;
    p.Manufacturer = DUETTE_DRIVER_MANUFACTURER;
    p.DeviceUID = DUETTE_TEST_MIC_UID;
    p.ModelUID = DUETTE_TEST_MIC_UID ".model";
    p.CanBeDefault = true;
    p.CanBeDefaultForSystemSounds = false;
    p.SampleRate = static_cast<UInt32>(kSampleRate);
    p.ChannelCount = kChannels;
    p.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
    p.ClockIsStable = true;
    p.ClockDomain = 0;  // not synchronized with anything
    return p;
  }
};

class TestSpeakerDevice final : public ClockedDevice {
 public:
  TestSpeakerDevice(std::shared_ptr<const aspl::Context> context,
                    std::shared_ptr<const SharedClock> clock48k,
                    std::shared_ptr<const SharedClock> clock44k)
      : ClockedDevice(std::move(context), parameters(), clock48k),
        clock48k_(std::move(clock48k)),
        clock44k_(std::move(clock44k)) {}

  void setStream(std::shared_ptr<aspl::Stream> stream) { stream_ = std::move(stream); }

 protected:
  const SharedClock& ioClock() const noexcept override {
    return GetNominalSampleRate() == 44100.0 ? *clock44k_ : *clock48k_;
  }

  bool willDo(UInt32 operationID) const noexcept override {
    return operationID == kAudioServerPlugInIOOperationWriteMix;
  }

  void doIO(UInt32 /*operationID*/, UInt32 /*frames*/, const AudioServerPlugInIOCycleInfo& /*cycle*/,
            void* /*buffer*/) noexcept override {
    // Discarded: the device only exists to be played into and tapped.
  }

  OSStatus SetNominalSampleRateImpl(Float64 rate) override {
    const OSStatus status = ClockedDevice::SetNominalSampleRateImpl(rate);
    if (status != kAudioHardwareNoError) return status;
    if (stream_) {
      // Called inside the HAL's configuration change, so these apply at once.
      const AudioStreamBasicDescription format = floatStreamFormat(rate);
      stream_->SetPhysicalFormatAsync(format);
      stream_->SetVirtualFormatAsync(format);
    }
    os_log_info(driverLog(), "Duette Test Speaker: sample rate %.0f", rate);
    return kAudioHardwareNoError;
  }

 private:
  static aspl::DeviceParameters parameters() {
    aspl::DeviceParameters p;
    p.Name = DUETTE_TEST_SPEAKER_NAME;
    p.Manufacturer = DUETTE_DRIVER_MANUFACTURER;
    p.DeviceUID = DUETTE_TEST_SPEAKER_UID;
    p.ModelUID = DUETTE_TEST_SPEAKER_UID ".model";
    p.CanBeDefault = true;
    p.CanBeDefaultForSystemSounds = false;
    p.SampleRate = static_cast<UInt32>(kSampleRate);
    p.ChannelCount = kChannels;
    p.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
    p.ClockIsStable = true;
    p.ClockDomain = 0;
    return p;
  }

  std::shared_ptr<const SharedClock> clock48k_;
  std::shared_ptr<const SharedClock> clock44k_;
  std::shared_ptr<aspl::Stream> stream_;
};

std::shared_ptr<const SharedClock> makeClock(const DriverClock& clock, double rate, double ppm) {
  ClockConfig config;
  config.sampleRate = rate;
  config.periodFrames = kZeroTimeStampPeriod;
  config.ppm = ppm;
  return std::make_shared<const SharedClock>(&machHostNow, clock.timebase, clock.anchorHostTime,
                                             config);
}

AudioStreamRangedDescription ranged(double rate) {
  AudioStreamRangedDescription d{};
  d.mFormat = floatStreamFormat(rate);
  d.mSampleRateRange.mMinimum = rate;
  d.mSampleRateRange.mMaximum = rate;
  return d;
}

}  // namespace

void addTestDevices(const std::shared_ptr<const aspl::Context>& context, aspl::Plugin& plugin,
                    const DriverClock& clock) {
  auto mic = std::make_shared<TestMicDevice>(
      context, makeClock(clock, kSampleRate, static_cast<double>(DUETTE_TEST_MIC_CLOCK_PPM)));
  aspl::StreamParameters micStream;
  micStream.Direction = aspl::Direction::Input;
  micStream.StartingChannel = 1;
  micStream.Format = floatStreamFormat(kSampleRate);
  mic->AddStreamAsync(micStream);

  auto speaker = std::make_shared<TestSpeakerDevice>(context, makeClock(clock, 48000.0, 0.0),
                                                     makeClock(clock, 44100.0, 0.0));
  aspl::StreamParameters speakerStream;
  speakerStream.Direction = aspl::Direction::Output;
  speakerStream.StartingChannel = 1;
  speakerStream.Format = floatStreamFormat(48000.0);
  auto stream = speaker->AddStreamAsync(speakerStream);
  stream->SetAvailablePhysicalFormatsAsync({ranged(44100.0), ranged(48000.0)});
  stream->SetAvailableVirtualFormatsAsync({ranged(44100.0), ranged(48000.0)});
  speaker->setStream(stream);
  speaker->SetAvailableSampleRatesAsync({{44100.0, 44100.0}, {48000.0, 48000.0}});

  plugin.AddDevice(mic);
  plugin.AddDevice(speaker);
  os_log(driverLog(), "Duette test devices added: %{public}s, %{public}s", DUETTE_TEST_MIC_NAME,
         DUETTE_TEST_SPEAKER_NAME);
}

}  // namespace duette::driver
