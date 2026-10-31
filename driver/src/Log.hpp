#pragma once

// Logging for the plug-in: os_log, subsystem me.roboroads.duette.driver.
//
//   log stream --predicate 'subsystem == "me.roboroads.duette.driver"' --level debug
//
// Never log from a real-time IO callback. Counters kept on the IO thread are logged later, from
// StartIO/StopIO, which the HAL calls on ordinary threads.

#include <aspl/Tracer.hpp>
#include <os/log.h>

namespace duette::driver {

inline constexpr const char* kLogSubsystem = "me.roboroads.duette.driver";

/// Plug-in lifecycle, devices, IO start and stop, property changes.
inline os_log_t driverLog() noexcept {
  static const os_log_t log = os_log_create(kLogSubsystem, "driver");
  return log;
}

/// libASPL's own trace of every HAL request. Debug level, so it costs nothing unless someone
/// turns debug logging on for the subsystem.
inline os_log_t asplLog() noexcept {
  static const os_log_t log = os_log_create(kLogSubsystem, "aspl");
  return log;
}

/// Sends libASPL's trace to os_log instead of syslog. libASPL traces real-time calls only when a
/// device sets EnableRealtimeTracing, which ours never do.
class OsLogTracer final : public aspl::Tracer {
 public:
  OsLogTracer() : aspl::Tracer(aspl::Tracer::Mode::Custom, aspl::Tracer::Style::Flat) {}

 protected:
  void Print(const char* message) override {
    os_log_debug(asplLog(), "%{public}s", message);
  }
};

}  // namespace duette::driver
