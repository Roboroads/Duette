# Architecture

How Duette is put together, as it is built. The code is the final word. This page says where to look and why it is shaped this way.

Duette takes the audio of one app through a Core Audio process tap, mixes it with a microphone, and presents the result as an input device called "Duette". Another app records "Duette" and gets both. Delay matters most, so the real-time path is small and has no locks.

## The audio path

```
 Discord (and its helper processes) --plays--> headphones     (the tap does not mute)
        |
        |  process tap: stereo mixdown of the app's processes, unmuted, private
        v
 +------------------ Duette.app: one private aggregate device -------------------+
 |  main and clock device: "Duette Sink" (hidden, output, 48 kHz)                |
 |  subdevices: "Duette Sink", and the microphone (drift compensation on)        |
 |  tap list: the app's tap (drift compensation on)                              |
 |                                                                               |
 |  one IOProc (C++, duette_engine_ioproc):                                      |
 |    in  = microphone channels + tap channels                                   |
 |    out = clip( g_out * clip( g_app * tap[L,R] + g_mic * mono(mic) ) )         |
 |    meters and counters go to relaxed atomics, gains come from atomics         |
 +-------------------------------------------------------------------------------+
        |  the HAL writes the output to "Duette Sink"
        v
 +------------------------ Duette.driver (inside coreaudiod) ------------------------+
 |  one shared clock for both devices                                               |
 |  LoopbackBuffer: ring indexed by sample time, 2 channels, 16384 frames           |
 |    Sink: DoIO(WriteMix)  writes at the sample time the HAL gives                 |
 |    Duette: DoIO(ReadInput) reads at its own sample time                          |
 +----------------------------------------------------------------------------------+
        |
        v
 "Duette" input device ---> OBS, QuickTime, Zoom, Discord, any number of readers
```

There is no custom IPC. The app hands audio to the driver by being an ordinary client of the hidden output device "Duette Sink". No shared memory or XPC has to cross coreaudiod's sandbox. The only other channel is a pair of custom properties on "Duette": one switches the self-test tone and one lists the processes reading it (see the driver section).

The mix, as the engine computes it: the microphone is averaged to mono and goes to both sides, a one-channel tap goes to both sides, the app and microphone gains and mutes apply, the sum is clipped to plus or minus 1, then the output gain and mute apply, the optional engine test tone replaces the mix, and the result is clipped again.

### Components

| Component | Path | Language | Role |
|---|---|---|---|
| DSP core | `core/` | C++17, header-only, no Apple dependencies | `LoopbackBuffer`, `SmoothedGain`, `Mixer`, `PeakRmsMeter`, `ToneGenerator`, `ZeroRunDetector`, the offline `LatencyEstimator` |
| HAL plug-in | `driver/` | C++17 on libASPL | Two devices on one clock, the loopback, the self-test tone, the input-client list, os_log |
| DuetteKit | `Packages/DuetteKit/` | SwiftPM: `DuetteEngine` (C++ with a C header) and `DuetteAudio` (Swift) | The real-time engine; Core Audio wrappers; tap and aggregate builders; the `EngineController` state machine; diagnostics |
| App | `app/` | Swift and SwiftUI, XcodeGen | Menu bar UI, welcome guide, permissions, settings, launch at login, Export Diagnostics |
| duettectl | `tools/duettectl/` | Swift on DuetteKit | Headless checks for CI and for a Mac with the driver installed |
| Packaging | `packaging/`, `scripts/`, `.github/workflows/` | shell and Actions | pkg, signing, notarization, install and uninstall, diagnose, release-please |

### Threads

| Thread | What runs there | Rules |
|---|---|---|
| HAL I/O thread of the app's aggregate | `duette_engine_ioproc` | No allocation, locks, logging, Objective-C or Swift. Reads parameter atomics, writes meters and counters. |
| coreaudiod I/O threads (driver) | The sink's write and the input's read | They touch the `LoopbackBuffer` and atomics only. Nothing is logged there. Counters are logged on StopIO. |
| Control queue (app) | Everything that changes a Core Audio object: tap, aggregate and IOProc build and teardown, property listeners | A serial queue behind the `ControlScheduler` protocol. Rebuild requests are debounced. |
| Main thread | SwiftUI | Polls the meters at 30 Hz through the C header, and reads the engine status. |

### Delay

At 128 frames and 48 kHz one buffer is 2.67 ms. The path has the aggregate's input buffer and safety offset, the drift-compensation resampler, the output buffer into the sink, the read by the client (the driver reports a safety offset of 16 frames and no latency), and the microphone's own hardware delay. The design figure is about 10 to 12 ms at 128 frames and about 7 ms at 64.

The app shows an estimate in "For experts" (`LatencyModel`). It adds up what the HAL reports: two aggregate buffers, the aggregate's input and output latency and safety offsets, and the reader's buffer, latency and safety offset on "Duette". The resampler is in no HAL property, so it is not in the estimate. `duettectl loopback` measures the driver part directly by writing a chirp into the sink and finding it in a recording of "Duette".

## DSP core (`core/include/duette/`)

Header-only C++17 with no Apple headers. It builds and tests on Linux (Catch2 with sanitizers, `scripts/ci/test-core.sh`), and the driver and the engine include the same headers, so the real-time code is tested once.

- `LoopbackBuffer<Channels, Capacity>`: a ring addressed by absolute sample time, `t` lives in slot `t mod Capacity`. One writer, any number of readers, wait-free. Each slot carries a tag with the sample time and a timeline number, which the writer retires before reusing a slot and publishes after writing. A reader checks the tag before and after copying, so a frame that was recycled mid-read comes back as zeros, never as a mix of two frames. Anything not validly written reads as zeros: after the writer's end (underrun, or the app isn't running), older than the capacity (stale), or in a gap. A write that goes back in time starts a new timeline and the old one stops being readable at once. The object is 256 KiB for 2 channels and 16384 frames, so it lives on the heap.
- `SmoothedGain`: a linear ramp over 5 ms, so gain and mute changes make no zipper noise. Mute is a ramp to 0 that keeps the gain.
- `Mixer`: the mix above. Interleaved and non-interleaved layouts go through one small view type (`SourceView`). A source with no channels is silence, NaN and infinity count as 0, gains are limited to 0 to 2 (+6 dB). After a ramp ends, a muted source is not even read.
- `PeakRmsMeter`: peak and RMS per block, stored in relaxed atomics. The UI does the decay.
- `ToneGenerator`: a sine with a phase accumulator, used by the engine's test tone and in CI.
- `ZeroRunDetector`: counts consecutive exact-zero frames. A process tap returns exact zeros when System Audio Recording is denied, which is how the app finds out.
- `LatencyEstimator`: offline, allocates, not for audio threads. Cross-correlates a known chirp against a recording and returns the lag and a confidence value. `duettectl` uses it.

An allocation guard test overrides `operator new` and expects zero calls during `Mixer::process` and the `LoopbackBuffer` read and write. There is no SPSC ring or resampler: the aggregate's drift compensation handles clock differences, and nothing so far needed more.

## HAL plug-in (`driver/`)

`Duette.driver` goes to `/Library/Audio/Plug-Ins/HAL/`. Bundle ID `me.roboroads.duette.driver`, version from `version.txt`. `Entry.cpp` exports `DuetteDriverEntryPoint`, which `CFPlugInFactories` in `Info.plist` points at, and returns libASPL's driver reference. coreaudiod only looks for plug-ins when it starts, which is why the pkg restarts it.

Two devices, both 2 channels of 32-bit float at 48 kHz only:

| | "Duette" | "Duette Sink" |
|---|---|---|
| UID | `me.roboroads.duette.device` | `me.roboroads.duette.sink` |
| Direction | input | output |
| Visible | yes | hidden: `GetIsHidden` is overridden to return true |
| Can be the default device | yes, but not for system sounds | no |
| Safety offset | 16 frames | 0 |

Hidden devices are not in `kAudioHardwarePropertyDevices`, so the app finds the sink with `kAudioHardwarePropertyTranslateUIDToDevice`.

**Shared clock.** `SharedClock` turns the host time into a zero timestamp: the latest period boundary at or before now, counted from one anchor taken when the plug-in loads. Both devices use one instance, with a period of 16384 frames and the same nonzero clock domain (`'Duet'`). A write to the sink at sample time `t` is read back from "Duette" at `t`. Nothing changes when IO starts or stops, so the clock is a pure function of host time and needs no lock. It has no Apple headers and is tested on Linux with a stub clock.

**No device mutex on the I/O path.** libASPL's `Device` serializes the zero timestamp and the IO operations with StartIO and StopIO through one mutex, and StartIO holds it while it traces. A second client starting IO could block the first one's IO thread. `ClockedDevice` overrides those entry points to skip the mutex. The IO state is atomics and the lock-free buffer only.

**Several writers.** The app's aggregate and a direct client such as `duettectl` can both write to the sink. `LoopbackWriter` keeps `LoopbackBuffer`'s one-writer rule with a try-acquired flag: a block that finds the flag taken is dropped and counted, never waited for. A block that starts before the end of what is already written would look like the clock going backward, so only its new tail is written.

**Self-test tone.** A custom property `'dtst'` on "Duette" (a CFNumber, 0 or 1, off by default, not persisted). While on, "Duette" plays a 440 Hz sine at -12 dBFS instead of the sink's audio. The tone and its on and off fade are pure functions of sample time and one atomic word, because several clients can read "Duette" at once from different threads. This proves the plug-in loads and plays with no app involved.

**Input clients.** A read-only property `'dcli'` on "Duette": a sorted CFArray of CFNumber PIDs of the clients between StartIO and StopIO. The driver sends a property-changed notification when the set changes (on StartIO, StopIO and RemoveClient, so a crashed client leaves the list too). coreaudiod marshals a plug-in's custom properties only as CFString or CFPropertyList, so both properties are listed in the custom property info as CFPropertyList and travel as CF objects. The definitions are in `driver/include/duette_driver_protocol.h`, plain C, mirrored by `DuetteDriver` in Swift.

**Test devices.** With `-DDUETTE_TEST_DEVICES=ON` (CI only, never shipped, and `build-driver.sh` checks the shipped bundle has none) the driver adds "Duette Test Mic", a 1 kHz tone on a clock 200 ppm fast to exercise drift compensation, and "Duette Test Speaker", an output at 48 or 44.1 kHz that discards what it gets, for `afplay` to play into so a tap has something to hear.

**Logging.** os_log, subsystem `me.roboroads.duette.driver`: load, StartIO and StopIO with the PID, client counts, and on the last StopIO the frames read and the frames that had no data. `log stream --predicate 'subsystem == "me.roboroads.duette.driver"'` follows it.

## Engine and control (`Packages/DuetteKit`)

### `DuetteEngine`: the real-time part

C++ behind `duette_engine.h`. `duette_engine_create` and `destroy` bracket the life of the app; aggregates come and go around one engine. The control side calls:

- `duette_engine_configure(layout)`, only while stopped. The layout says which buffers of the aggregate's input list are the microphone and which are the tap, which output buffers belong to the sink, and the sample rate. It resets meters and zero runs and keeps gains, mutes and counters.
- `duette_engine_set_gain` and `set_mute` for three stages: the app, the microphone and the output (the whole mix). Atomics, any thread.
- `duette_engine_set_test_tone`: a 440 Hz tone at -12 dBFS in place of the mix, cross-faded over 5 ms.
- `duette_engine_read_meters` and `read_stats`: peak and RMS for the app, the microphone and the output, plus cycles, frames, zero runs, layout mismatches, overloads, and whether the tap has delivered any non-zero sample yet. The source meters read before their gain and mute. The output meter reads what goes to the sink.
- `duette_engine_start` and `stop` register `duette_engine_ioproc` with `AudioDeviceCreateIOProcID` and start it.

The IOProc zeroes the output first, so whatever it doesn't write is silence. A cycle whose buffer lists don't fit the layout writes silence and counts a mismatch. `MixEngine` is the Swift face of all this.

### `DuetteAudio`: the control plane

- `AudioObject` and `HAL`: property helpers, device and process object lookup, the driver's custom properties (`HAL.setDriverSelfTestTone`, `HAL.inputReaderPIDs`).
- `DeviceCatalog`: the microphone choices are "System default" and every input device except hidden ones, "Duette", "Duette Sink" and any private aggregate. A microphone that is "Duette" would feed the mix into itself.
- `ProcessCatalog`: turns the HAL's process objects into apps. A process belongs to an app when (1) its bundle ID is the app's, (2) its bundle ID is the app's plus a dot and more (`com.hnc.Discord.helper.Renderer` belongs to `com.hnc.Discord`, `com.hnc.DiscordX` does not), (3) following its parent PIDs reaches one of the app's processes, or (4) the process macOS holds responsible for it is one of the app's. Rule 4 is what puts WebKit's XPC helpers, which launchd starts, under Safari. Duette's own process never belongs to an app. App names and icons come from `NSRunningApplication`; the picker lists running apps with those playing audio first.
- `TapController`: `CATapDescription(stereoMixdownOfProcesses:)`, `muteBehavior = .unmuted`, private, `AudioHardwareCreateProcessTap`.
- `AggregateBuilder`: the description dictionary of a private, non-stacked aggregate with UID `me.roboroads.duette.agg.<pid>`. The main and clock device is the sink. The subdevices are the sink and the microphone, with drift compensation on the microphone. The tap goes in the tap list with drift compensation and auto start. The buffer size is set on the aggregate afterwards. A running aggregate is never changed in place.
- `StreamLayoutResolver`: finds out which of the aggregate's streams belong to the sink, the microphone and the tap. The order of tap streams against subdevice streams is not documented, so it is not assumed. It tries, in order: the members' own stream objects, stream ownership, and the one order of members whose channel counts fit. Only if none of those tells them apart does it fall back to composition order, and the method used is written to the diagnostics. The result is checked against the aggregate's `kAudioDevicePropertyStreamConfiguration`, and a mismatch is an error that goes through the retry path.
- `FeedbackLoopDetector`: the tapped app's processes (helpers included) intersected with the processes reading "Duette". Duette's own PID never counts. The reading set is `'dcli'` plus the HAL process objects that run input IO on "Duette", also through an aggregate, because the HAL starts a device's IO once for all its readers and a process that starts reading while another already does is missing from `'dcli'`. It only warns. The audio is left alone.
- `AudioSystem`: a protocol with everything the controller needs from Core Audio. `CoreAudioSystem` is the real one, with listeners for devices, default input, the process list, `kAudioHardwarePropertyServiceRestarted`, sleep and wake, and the watched devices and aggregate. Tests give the controller a fake.
- `DiagnosticsCollector`, `LatencyModel`, `MeterHistory`: the report behind "Export Diagnostics…". `MeterHistory` samples the levels every 0.5 s for two minutes and the report gives their range over the last 60 s.

### `EngineController`: the state machine

States: `idle`, `waitingForDriver`, `waitingForApp(bundleID)`, `running(none | micOnly | appOnly | both)` and `error(status, attempt)`. With the sink missing it waits for the driver and builds as soon as the sink appears. With an app chosen but not running it runs with the microphone and adds the app when its processes appear.

A build does, in order: look up the sink and the microphone, find the app's process objects and create the tap, create the aggregate, set its buffer size, resolve the stream layout, configure the engine, start the IOProc, and publish the new status. A failure at any step tears down what was built, sets `error` with the OSStatus, and retries after 1 second, then 2, then every 5 seconds until a build works.

**Every rebuild is a full teardown and build on the control queue, debounced by 250 ms.** The triggers:

- the selected app's set of process objects changes (a helper starts or exits, the app quits or comes back);
- the microphone disappears or returns, or the default input changes while "System default" is selected. The controller compares the sink and microphone with what the last attempt used, successful or not, so the notifications that Duette's own aggregates cause don't start a loop, including during the retry wait;
- the sink appears or disappears, or coreaudiod restarts;
- the sample rate or stream layout of the sink or the microphone changes;
- wake from sleep. On sleep it stops and goes to `idle`;
- the user changes the app, the microphone or the buffer size (64, 128, 256 or 512 frames).

**Monitoring**, every 0.5 s: record the meters, look again for a feedback loop, and decide whether capture looks denied. Capture looks denied when the tap has delivered only exact zeros since it was built, for more than 3 seconds, while one of the app's processes is running output. Once the tap has delivered any sound, later silence counts as a quiet app. A `kAudioDeviceProcessorOverload` listener on the aggregate counts missed deadlines into the engine stats.

## The app on top

The app's `AppModel` owns the `EngineController` and `Settings` (UserDefaults, with a version key; launch at login is read from `SMAppService` every time and never cached). `StatusLine` turns the engine status into the one sentence, colour and button at the top of the menu, in words that name no part of this page. The engine is started only after the welcome guide's app sound screen, because the engine start is what makes macOS ask about the app's sound. Details are in `app/Duette/`.

## What differs from what you might guess

- There are three gain stages, not two: the app, the microphone and a master after the mix.
- Feedback detection uses `'dcli'` together with the HAL's process objects.
- The driver doesn't take libASPL's device mutex on the I/O path, and its writer tolerates several writers.
- Nothing resamples except the aggregate's drift compensation. `duettectl rate-mismatch` checks a tap at 44.1 kHz only (the test speaker). A microphone at another rate has no automated check.
- "Export Diagnostics…" doesn't write to the Desktop by itself. It builds the zip in a scratch folder and asks where to put it with a Save panel, which needs no permission to write to the Desktop and doesn't trigger macOS's question about it.
