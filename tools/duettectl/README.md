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
| `loopback` | Plays a chirp and then a 1 kHz tone into the hidden sink while recording "Duette": the chirp comes back at the same sample time, the latency from the writer's IOProc call to the reader's is at most 2 buffers + 64 frames, and "Duette" is silent within a buffer of the writer's last frame. |
| `engine` | Runs EngineController headless (`--mic`, `--pid` or `--app`, `--seconds`), optionally records "Duette" and checks it for tones (`--expect 1000@-12`). |
| `verify-mic` | Engine with "Duette Test Mic" (1 kHz on a clock 200 ppm fast): the tone arrives at -12 dBFS through drift compensation; mic gain, mute, output gain, meters and the engine's test tone. |
| `hidden-agg` | Engine with only the hidden sink: it is the aggregate's main and clock device, the IOProc runs at the sink's rate, and the engine's tone reaches "Duette". |
| `verify-mix` | afplay plays 440 Hz into "Duette Test Speaker"; the engine taps it and mixes the test mic: both tones at -12 dBFS, app gain and mutes. `--expect-denied` checks what happens when System Audio Recording is denied. |
| `rate-mismatch` | `verify-mix` with the test speaker, and so the tap, at 44.1 kHz. |
| `dcli` | The driver's `'dcli'` lists this process while it reads "Duette" directly, through its own aggregate (`--mode aggregate`, as call apps do) or through the voice-processing unit (`--mode vpio`), and drops it after. |
| `feedback-loop` | A separate process that plays audio and reads "Duette" through an aggregate: `'dcli'` names it, ProcessCatalog groups it, FeedbackLoopDetector fires, and Duette's own reading never counts. `--controller` also checks EngineController's warning (needs a working tap). |
| `soak` | Engine with the test mic (and `--with-app` a tapped tone) for `--minutes`: every second of "Duette" has the tones, no dropouts, no overloads. |
| `record`, `play`, `make-tone`, `analyze`, `set-default`, `set-rate`, `whoami` | Tools for the above and for poking at a machine by hand. |

Apps given as `--pid` are passed to EngineController as the bundle ID `pid:<n>`: a CLI process
such as afplay has no app bundle, and everything else about the controller stays as in the app.
