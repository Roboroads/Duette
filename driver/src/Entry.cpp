// Entry point of Duette.driver. coreaudiod finds it through CFPlugInFactories in Info.plist.

#include "DuetteDevices.hpp"
#include "Log.hpp"
#include "duette_driver_protocol.h"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <memory>

namespace {

std::shared_ptr<aspl::Driver> createDriver() {
  using namespace duette::driver;

  auto context = std::make_shared<aspl::Context>(std::make_shared<OsLogTracer>());

  // One anchor for the life of the plug-in, taken now, at load.
  const DriverClock clock = makeDriverClock();

  aspl::PluginParameters pluginParams;
  pluginParams.Manufacturer = DUETTE_DRIVER_MANUFACTURER;
  auto plugin = std::make_shared<aspl::Plugin>(context, pluginParams);

  addDuetteDevices(context, *plugin, clock);
#if DUETTE_TEST_DEVICES
  addTestDevices(context, *plugin, clock);
#endif

  os_log(driverLog(),
         "Duette driver %{public}s loaded: %u devices, timebase %u/%u, test devices %{public}s",
         DUETTE_DRIVER_VERSION, static_cast<unsigned>(plugin->GetDeviceCount()),
         static_cast<unsigned>(clock.timebase.numer), static_cast<unsigned>(clock.timebase.denom),
         DUETTE_TEST_DEVICES ? "on" : "off");

  return std::make_shared<aspl::Driver>(context, plugin);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void* DuetteDriverEntryPoint(
    CFAllocatorRef /*allocator*/, CFUUIDRef requestedTypeUUID) {
  if (requestedTypeUUID == nullptr || !CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
    return nullptr;
  }
  // Built once and kept for the life of coreaudiod's plug-in host.
  static std::shared_ptr<aspl::Driver> driver = createDriver();
  return driver->GetReference();
}
