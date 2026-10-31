# duettectl

A command-line tool on DuetteKit that checks the Duette driver and engine on a machine with
nobody at it. CI runs it from `scripts/ci/integration.sh` (workflow `integration.yml`); it also
works on a Mac with the driver installed.

Build it with `scripts/ci/build-cli.sh` (product: `build/out/duettectl`). Run
`duettectl help <command>` for a command's options.

Every check prints one line:

```
CHECK PASS loopback.latency: 272 frames (5.67 ms) | largest, writer IOProc call to reader IOProc call; ...
```

With `--report FILE` each check is also appended to FILE, tab-separated, which
`integration.sh` turns into the job summary. The exit status is 0 when no check failed, 1 when
one did, 2 for a usage error and 124 when the watchdog (`--timeout`) ended a command that got
stuck in a Core Audio call.

| Command | What it checks |
|---|---|
| `list` | Devices with their buffer, latency and safety offsets; "Duette" is listed, "Duette Sink" is found by UID but hidden; `--test-devices` also wants the CI test devices. |
| `selftest` | Turns the driver's tone (`'dtst'`) on, records "Duette": 440 Hz at -12 dBFS on both channels; off again: exact silence. |
| `loopback` | Plays a chirp and then a 1 kHz tone into the hidden sink while recording "Duette": the chirp comes back at the same sample time, the latency from the writer's IOProc call to the reader's is what the HAL's buffer, latency and safety-offset figures add up to, within 1 ms either way, and "Duette" is silent within a buffer of the writer's last frame. |
| `latency` | "Measure latency" as the app runs it: EngineController pauses the engine, a chirp goes through the sink into "Duette" (the probe IOProcs and the analysis are DuetteKit's), and the engine starts again on the same aggregate. The measured loopback must match the app's estimate to within 1 ms; `total` says what Duette adds (the loopback) and the whole way from the mic to a reader. `--mic default` on a Mac without the CI test devices. |
| `engine` | Runs EngineController headless (`--mic`, `--pid` or `--app`, `--seconds`), optionally records "Duette" and checks it for tones (`--expect 1000@-12`). |
| `verify-mic` | Engine with "Duette Test Mic" (1 kHz on a clock 200 ppm fast): the tone arrives at -12 dBFS through drift compensation; mic gain, mute, output gain, meters and the engine's test tone. |
| `hidden-agg` | Engine with only the hidden sink: it is the aggregate's main and clock device, the IOProc runs at the sink's rate, and the engine's tone reaches "Duette". |
| `verify-mix` | afplay plays 440 Hz into "Duette Test Speaker"; the engine taps it and mixes the test mic: both tones at -12 dBFS, app gain and mutes. `--expect-denied` checks what happens when System Audio Recording is denied. |
| `rate-mismatch` | `verify-mix` with the test speaker, and so the tap, at 44.1 kHz. |
| `dcli` | The driver's `'dcli'` lists this process while it reads "Duette" directly (`--mode direct`), through its own aggregate (`--mode aggregate`, as call apps do) or through the voice-processing unit (`--mode vpio`), and drops it after. `--mode concurrent` has another process read first: both must be listed. |
| `feedback-loop` | This process reads "Duette", then a separate process that plays audio reads it through an aggregate: `'dcli'` names both, ProcessCatalog groups the app, FeedbackLoopDetector fires for it and never for this process. `--controller` also checks EngineController's warning (needs a working tap). |
| `soak` | The engine for `--minutes` per buffer size (`--buffers 128,64`, default `--buffer`). In CI, with the test mic (and `--with-app` a tapped tone): every second of "Duette" has the tones. With a real mic (`--hands-on`, `--mic default` or a UID, `--app BUNDLE_ID`): no second with sound has a gap of exact zeros that the mic did not deliver itself, and at least half the seconds had sound. Both: no overloads (also counted per minute), the mic's drift against the sink in ppm, and "Measure latency" at the end. A failed second with no overload during it is counted apart (`windows.unexplained`). One `SOAK PASS`, `SOAK FAIL` or `SOAK INCONCLUSIVE` line sums it up; `--out FILE` writes the result. See below for a tester's Mac. |
| `overloads` | A control: counts the HAL's late-cycle reports (`kAudioDeviceProcessorOverload`) on any device, or an aggregate of two (`--with`), with an IOProc that only copies samples. It tells a machine that cannot keep time from a problem in Duette. |
| `record`, `play`, `make-tone`, `analyze`, `set-default`, `set-rate`, `whoami` | Tools for the above and for poking at a machine by hand. |

Apps given as `--pid` are passed to EngineController as the bundle ID `pid:<n>`: a CLI process
such as afplay has no app bundle, and everything else about the controller stays as in the app.

## Soak on a real Mac

The CI runner is a virtual machine that misses audio deadlines on its own (a do-nothing IOProc
on its own devices gets them too), so whether Duette runs without a single dropout is decided
on a real Mac. The installer puts duettectl in `/Library/Application Support/Duette/`, next to
the uninstaller. On the tester's Mac:

1. Quit the Duette app (Duette in the menu bar > Quit Duette). duettectl runs its own engine,
   and two would write to "Duette" at once; the soak refuses to start while the app runs.
2. Open Terminal and paste:

   ```
   "/Library/Application Support/Duette/duettectl" soak --hands-on
   ```

3. If macOS asks whether Terminal may use the microphone, allow it: the soak records your
   microphone through Duette. Keep sound going near the microphone for the whole 22 minutes
   (play music near the Mac, or a podcast): a gap can only show in a second that has sound.

`--hands-on` means: the system default microphone, a 30-second control run (late cycles on the
default output with an IOProc that plays silence: what this Mac does without Duette), then
10 minutes at 128 frames and 10 at 64, each ending with "Measure latency". Every option can be
given as well, for example `--minutes 5`, `--mic <UID>` (UIDs are in `duettectl list`), or
`--app com.hnc.Discord` to tap Discord too (it must be running and playing; macOS then asks
about System Audio Recording for Terminal).

It prints a line a minute, then the checks, then:

```
SOAK PASS: 10 min at 128 and 64 frames each: no dropouts, no missed deadlines
Send this file: /Users/<you>/Desktop/Duette-soak-20261031-142233.txt
```

or `SOAK FAIL: <check>: <value>` naming the first check that failed, for example
`SOAK FAIL: 64.overloads: 3`, or, when too little sound reached the microphone to test
anything:

```
SOAK INCONCLUSIVE: 128.sound: 120 of 600 seconds had sound. Keep sound going near the microphone (play music or keep talking) and run it again.
```

The exit status is 0 for PASS, 1 for FAIL and 2 for INCONCLUSIVE. The verdict comes last,
after the file is written; the file is created when the soak starts (if the Desktop cannot be
written, it goes to the current folder, and the soak says so). It starts with the same line,
then the date, macOS version, Mac model, driver version and default devices, then every check,
then the minutes that had late cycles and when each failed second happened. Checks are named
after the buffer size:

| Check | What it says |
|---|---|
| `control.default-output` | Late cycles on the Mac's own output in 30 s, without Duette. |
| `<N>.state` | The engine ran with the mic (and the app). |
| `<N>.signal` | Sound came through within 15 s. Only silence means Terminal may not use the microphone, or the room is quiet (INCONCLUSIVE). |
| `<N>.windows`, `<N>.dropouts` | Seconds with sound that had a run of 32 or more exact zeros the mic did not deliver itself (frames that never arrived), and the longest such run. |
| `<N>.mic-zeros` | Seconds whose exact zeros came from the mic itself (a mute switch, a noise gate), compared with a recording of the mic: not dropouts. |
| `<N>.silent-windows` | Seconds of exact silence throughout: nothing came in, which is not a dropout. |
| `<N>.sound` | How many seconds had sound (less than 10% exact zeros). Under half makes the soak INCONCLUSIVE. |
| `<N>.overloads`, `<N>.reader-overloads`, `<N>.overloads-per-minute` | Missed deadlines (`kAudioDeviceProcessorOverload`) on the engine's aggregate and on "Duette", in all and minute by minute. |
| `<N>.windows.unexplained` | Failed seconds with no missed deadline at the same time: those are Duette's own fault. |
| `<N>.drift` | How many ppm the mic's clock runs from the sink's, from their time stamps. The aggregate's drift compensation takes care of it. |
| `<N>.latency.measured`, `<N>.latency.matches-estimate`, `<N>.latency.total` | "Measure latency": the loopback measured, how far it is from the app's estimate (limit 1 ms), what Duette adds and the whole way from the mic to other apps. |

