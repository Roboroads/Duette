# Duette

Duette mixes the sound of one app, for example a Discord call, with your microphone, and shows the result to other apps as a microphone called "Duette". Pick "Duette" as the microphone in OBS, Zoom or QuickTime and they get you and the caller together, in sync. You keep hearing the call in your headphones as usual.

It runs from the menu bar, is built to add very little delay (the goal is under 20 milliseconds), and is free software under the GPL-3.0.

## What you need

- A Mac with an Apple chip (M1 or newer). Macs with an Intel processor don't work.
- macOS 14.2 or newer. The first round of hands-on testing is on macOS 15.
- Headphones. Without them the speakers will play the call into your microphone.

## Install

1. Go to the [releases page](https://github.com/Roboroads/Duette/releases) and download the file that ends in `.pkg` from the newest release. Early versions are labelled "Pre-release" there. That is expected.
2. Open the file you downloaded and follow the installer. There is nothing to choose, and it asks for your Mac's password.
3. Sound on your Mac pauses for a second or two while the installer finishes. Then the Duette icon (a circle with a sound wave) appears at the top of your screen and a welcome guide opens.

Normal releases are checked by Apple, so macOS opens the installer without a warning. A test version may not be. If macOS says it can't open the file or can't check it, close the message, open System Settings, then Privacy & Security, scroll down to the message about the installer and click "Open Anyway". Then open the file again.

## First run

The welcome guide has four screens and one big button on each.

1. What Duette does.
2. "Allow microphone". macOS asks if Duette may use your microphone. Allow it, or the people you talk to can't hear you through Duette.
3. Which app to share. If Discord is installed, it is already chosen. macOS asks if Duette may record the sound of that app, now or the first time the app plays sound. Allow it.
4. A reminder to pick "Duette" as the microphone in the app you record or call with.

You can bring the guide back from the Duette menu with "Show the welcome guide".

## Use it with Discord and OBS, Zoom or QuickTime

1. Start Discord and join a call.
2. Click the Duette icon. Check that "Sound from Discord" is showing. If not, open the popup in that row and choose Discord.
3. In the app you record or call with, choose "Duette" as the microphone:
   - OBS: add an "Audio Input Capture" source and choose "Duette" as its device.
   - Zoom: Settings, then Audio, then Microphone, then "Duette".
   - QuickTime Player: File, then New Audio Recording, click the small arrow next to the red button and choose "Duette".
4. Leave Discord's own input on your real microphone. Don't choose "Duette" there. Discord would then send its own call back to the people in it, and they would hear themselves. Duette notices this, puts an orange dot on its menu bar icon and shows a warning in the menu.

The status line at the top of the menu says in one sentence how it is going: a green dot when it works, orange when it is waiting for something (for example "Waiting for Discord to start", which clears by itself when you open Discord), red when you need to do something (for example allow a permission), with a button for it.

If you only want your voice, choose "No app, only my microphone".

## What is in the menu

- "Sound from ...": which app to share, its volume (0% to 200%), "Mute" and a level bar.
- "Your microphone": which microphone, its volume, "Mute" and a level bar. "System default" follows whatever your Mac uses.
- "What other apps hear": the volume, mute and level of the mix.
- "Open Duette when I log in".
- "For experts": settings most people never need. The buffer size, an estimate of the delay, a count of missed deadlines and two test tones.
- "Export Diagnostics…", "Show the welcome guide", "About Duette" and "Quit Duette".

Mute and the volumes only change what goes into "Duette". What you hear yourself never changes.

If you can't see the menu bar icon (a full menu bar, or the notch is in the way), open Duette from the Applications folder again. A window opens with the same controls.

## When something is wrong

| What you see | What to do |
|---|---|
| "Duette" is not in the microphone list of OBS or Zoom | Open System Settings, then Sound. If "Duette" isn't under Input, restart the Mac, or open the installer file again. |
| "Duette needs permission to hear (app)" | Click "Open Settings". Scroll to "System Audio Recording Only" and switch Duette on. |
| "Duette needs permission to use your microphone" | Click "Open Microphone Settings" and switch Duette on. |
| "Your microphone isn't connected" | Plug it in, or choose another one. Duette picks it up again by itself. |
| Callers hear themselves | An orange warning in the menu names the app. In that app, choose your real microphone instead of "Duette". |
| Anything else | Right after it happens, click "Export Diagnostics…", save the file and send it to whoever is helping you. It has details about your audio devices and Duette's own log from the last half hour, and no audio. |

If Duette won't open at all, open Terminal (press Command and Space, type Terminal, press Return), paste this and press Return, and send the file it puts on your Desktop:

```sh
sudo "/Library/Application Support/Duette/duette-diagnose.sh"
```

## Uninstall

Open Terminal (press Command and Space, type Terminal, press Return), paste this and press Return:

```sh
sudo "/Library/Application Support/Duette/uninstall.sh"
```

It asks for your password, quits Duette, takes it out of your Login Items and removes the app and the part that adds the "Duette" microphone to your Mac. Sound pauses for a moment. Your Duette settings stay in `~/Library/Preferences`, so a later reinstall keeps them. If the script says it could not take Duette out of Login Items by itself, open System Settings > General > Login Items & Extensions and remove Duette there.

## Known limitations

- One app at a time. You can't share two apps together.
- Apple chip and macOS 14.2 or newer only.
- No sound effects: no equaliser or noise reduction.
- Sound can cut out for a fraction of a second when you change the app or the microphone, plug a microphone in or out, a call starts, or your Mac wakes up.
- If you don't give Duette the permission to hear other apps, their sound arrives as silence. Duette notices after a few seconds and tells you.
- No automatic updates. To update, download the newer installer file and open it. It replaces the old version.

The technical limits are listed under "For developers".

## Privacy

Duette doesn't connect to the internet. Audio stays on your Mac, and nothing is recorded or stored. "Export Diagnostics…" only writes a file where you choose, and sending it is up to you.

## For developers

How it works inside: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The hands-on checklist: [docs/TESTING.md](docs/TESTING.md). Releases and test builds: [docs/RELEASING.md](docs/RELEASING.md). Signing and notarization: [docs/SIGNING.md](docs/SIGNING.md). Project conventions for contributors: [CLAUDE.md](CLAUDE.md).

### Repo layout

| Path | What lives there |
|---|---|
| `core/` | Header-only C++17 DSP library (mixer, loopback buffer, meters, tone). No Apple dependencies, so it builds and tests on Linux. |
| `driver/` | The HAL plug-in `Duette.driver`, C++17 on [libASPL](https://github.com/gavv/libASPL), built with CMake. |
| `Packages/DuetteKit/` | Local SwiftPM package: `DuetteEngine` (the real-time mix in C++ behind a C header) and `DuetteAudio` (Core Audio wrappers and the engine state machine). |
| `app/` | The SwiftUI menu bar app. The Xcode project is generated from `app/project.yml` with XcodeGen and is never committed. |
| `tools/duettectl/` | Swift command-line tool on DuetteKit for checks without a person at the keyboard. |
| `packaging/` | The installer's distribution file, install scripts and `uninstall.sh`. |
| `scripts/` | Install, sign, notarize, pkg and diagnose scripts. `scripts/ci/` has the entry points CI calls, see its [README](scripts/ci/README.md). |
| `docs/` | The docs above. |
| `.github/workflows/` | CI, integration, soak, packaging and release workflows. |
| `version.txt` | The single source of the version. release-please owns it. |

### Building without a Mac

Swift and Apple frameworks only compile on macOS, so if you don't have a Mac, GitHub Actions is the compiler. CI runs on pull requests and on pushes to `main`: the DSP core on Linux, everything else on a `macos-15` runner. Open a draft PR, push often and read the run's logs. The macOS job uploads everything under `build/out/` as the `duette-build` artifact.

On Linux you can build and test `core/` and the driver's unit tests (they use no Apple headers):

```sh
scripts/ci/test-core.sh plain
cmake -S driver -B build/driver-tests -DDUETTE_DRIVER_BUILD_TESTS=ON
cmake --build build/driver-tests
ctest --test-dir build/driver-tests
```

To get an installer of any branch onto a real Mac without cutting a release, see "A test build from any branch" in [docs/RELEASING.md](docs/RELEASING.md).

### Building on a Mac

You need Xcode (with the macOS SDK), CMake and Homebrew. `build-app.sh` installs XcodeGen with Homebrew if it is missing.

```sh
scripts/ci/test-core.sh        # DSP core, with sanitizers
scripts/ci/build-driver.sh     # build/out/Duette.driver, plus the unit tests
scripts/ci/build-kit.sh        # DuetteKit: swift build and swift test
scripts/ci/build-app.sh        # build/out/Duette.app, plus the app's unit tests
scripts/ci/build-cli.sh        # build/out/duettectl, plus its tests
```

The products are Release builds for arm64, ad-hoc signed, in `build/out/`. Install them on your own Mac, and remove them again, with:

```sh
sudo scripts/install.sh
sudo scripts/uninstall.sh
```

`install.sh` restarts `coreaudiod`, so audio stops for a moment in every app. To build the installer from what is in `build/out/`, run `scripts/build-pkg.sh`. It leaves the pkg unsigned unless the signing certificates are available (see [docs/SIGNING.md](docs/SIGNING.md)).

### Tests

| What | How | Where it runs |
|---|---|---|
| DSP core (Catch2, plus AddressSanitizer, UndefinedBehaviorSanitizer and ThreadSanitizer) | `scripts/ci/test-core.sh [plain\|asan\|tsan]` | Linux and macOS |
| Driver unit tests: shared clock, loopback writer, test tone | `scripts/ci/build-driver.sh`, or the CMake commands above | Linux and macOS |
| DuetteKit: engine IOProc with synthetic buffers, the state machine against a fake audio system | `scripts/ci/build-kit.sh` | macOS |
| The app: model, settings, status line, onboarding, diagnostics | `scripts/ci/build-app.sh` | macOS |
| duettectl: arguments, WAV files, the tone checker | `scripts/ci/build-cli.sh` | macOS |
| Driver and engine against the real Core Audio, with test devices, including "Measure latency" against the app's estimate | `integration.yml`, which calls `scripts/ci/integration.sh` | CI only |
| Ten-minute soak at 64 and 128 frames, with test devices | `soak.yml` (nightly, by hand, or on a pull request labelled `soak`) | CI only; the runner is a virtual machine, so it may report "needs hands-on" |
| Soak with a real microphone: about 22 minutes, 10 each at 128 and 64 frames, ending in `SOAK PASS`, `SOAK FAIL` or `SOAK INCONCLUSIVE` | `duettectl soak --hands-on`, step 2.11 of [docs/TESTING.md](docs/TESTING.md) | A real Mac with the installed pkg |
| The installer: lint, a pkg from stand-in bundles, install, diagnose, uninstall | `packaging.yml` | CI only |
| Everything that needs a person, a microphone and Discord | [docs/TESTING.md](docs/TESTING.md) | A real Mac |

`duettectl` is also installed with the pkg, at `/Library/Application Support/Duette/duettectl`. Its commands are listed in [tools/duettectl/README.md](tools/duettectl/README.md).

### Technical limits

- "Duette" is 48 kHz stereo only. Other apps convert to that on their own. The microphone is mixed down to mono and sent equally to the left and right side.
- Volumes go up to 200% (+6 dB). Anything past full scale is hard-clipped. There are no effects.
- macOS has no public way to ask whether System Audio Recording was allowed. A denied tap delivers exact zeros, but so does a call where nobody talks. So after more than 3 seconds of exact zeros while the shared app is playing, the app asks macOS's own privacy check (a private call, looked up at run time, macOS 14.4 and newer). "Denied" shows the red line at once, also if the permission is switched off while Duette runs. "Allowed" never does. Without an answer, the line shows only if the tap has never carried sound, so a permission switched off mid-call then shows up the next time the audio path is rebuilt.
- Every rebuild of the audio path leaves a gap of a fraction of a second. The triggers are listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Nothing resamples except the drift compensation of the aggregate device. CI checks a tap at 44.1 kHz (`duettectl rate-mismatch`), not a microphone at another rate.
- The delay is designed to be about 10 to 12 ms at 128 frames. "Measure latency" under "For experts" measures it with a test sound (apps listening to Duette hear a short silence and a soft chirp or two meanwhile). The first measurements on a real Mac are part of the hands-on test in [docs/TESTING.md](docs/TESTING.md).
- arm64 only, not sandboxed, not on the App Store, no updater.

### Contributing and releasing

Commits are one Conventional Commits line with no body. PRs are squash-merged, and the PR title is what [release-please](https://github.com/googleapis/release-please) reads, so write it as `feat:`, `fix:` or `docs:`, and put `!` after the type for a breaking change. Don't edit `version.txt` or `CHANGELOG.md` by hand.

release-please keeps one release PR open. Merging it tags the version, creates the GitHub release (a pre-release while the version starts with `0.`), and starts the signed, notarized build that attaches the pkg, `uninstall.sh`, `TESTING.md` and `SHA256SUMS`. The one-time setup and the details are in [docs/RELEASING.md](docs/RELEASING.md).

## License

Duette is free software under the [GNU General Public License v3.0](LICENSE).
