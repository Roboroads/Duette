# Duette

Duette mixes the sound of one app, for example a Discord call, with your microphone, and shows the result to other apps as a microphone called "Duette". Pick "Duette" as the microphone in OBS, Zoom or QuickTime and they get you and the caller together, in sync. You keep hearing the call in your headphones as usual.

It runs from the menu bar, is built for low delay (the goal is under 20 ms), and is free software under the GPL-3.0.

## What you need

- A Mac with Apple silicon (M1 or newer). Intel Macs are not supported.
- macOS 14.2 or newer. The first round of hands-on testing is on macOS 15.
- Headphones. Without them the speakers will play the call into your microphone.

## Install

1. Go to the [releases page](https://github.com/Roboroads/Duette/releases) and download `Duette-<version>.pkg` from the newest release. Early versions are marked as pre-release there. That is expected.
2. Double-click the pkg and follow the installer. There are no choices to make, and it asks for your password.
3. The sound on your Mac pauses for a second or two while the audio system restarts. Then the Duette icon (a circle with a sound wave) appears at the top of your screen and a welcome guide opens.

Release builds are signed and notarized by Apple, so macOS opens them without a warning. A test build may not be. If macOS says it can't open or check the pkg, close the message, open System Settings, then Privacy & Security, scroll down to the message about the pkg and click "Open Anyway". Then open the pkg again.

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
- "For experts": the buffer size (64, 128, 256 or 512 frames, 128 by default), an estimate of the delay, a count of missed deadlines, and two test tones.
- "Export Diagnostics…", "Show the welcome guide", "About Duette" and "Quit Duette".

Mute and the volumes only change what goes into "Duette". What you hear yourself never changes.

If you can't see the menu bar icon (a full menu bar, or the notch is in the way), open Duette from the Applications folder again. A window opens with the same controls.

## When something is wrong

| What you see | What to do |
|---|---|
| "Duette" is not in the microphone list of OBS or Zoom | Open System Settings, then Sound, then Input. If it isn't there, restart the Mac, or run the installer again. |
| "Duette needs permission to hear (app)" | Click "Open Settings". Scroll to "System Audio Recording Only" and switch Duette on. |
| "Duette needs permission to use your microphone" | Click "Open Microphone Settings" and switch Duette on. |
| "Your microphone isn't connected" | Plug it in, or choose another one. Duette picks it up again by itself. |
| Callers hear themselves | An orange warning in the menu names the app. In that app, choose your real microphone instead of "Duette". |
| Anything else | Click "Export Diagnostics…", save the zip and send it to whoever is helping you. It has details about your audio devices and Duette's own log, and no audio. |

If the app won't open at all, run this in Terminal and send the zip it puts on your Desktop:

```sh
sudo "/Library/Application Support/Duette/duette-diagnose.sh"
```

## Uninstall

Open Terminal and run:

```sh
sudo "/Library/Application Support/Duette/uninstall.sh"
```

It quits Duette, removes the app, the audio driver and its support folder, and restarts the audio system, which pauses sound for a moment. Your Duette settings stay in `~/Library/Preferences`, so a later reinstall keeps them.

## Known limitations

- One app at a time. You can't share two apps together.
- "Duette" is 48 kHz stereo only. Other apps convert to that on their own. Your microphone is mixed down to mono and sent equally to the left and right side.
- No effects: no equaliser, noise reduction or compressor. Volumes go up to 200% (+6 dB) and anything past full scale is clipped.
- Apple silicon and macOS 14.2 or newer only.
- macOS has no way to ask whether the "System Audio Recording" permission was given. If it wasn't, the app's sound arrives as silence. Duette notices after a few seconds and tells you.
- Whenever Duette rebuilds its audio path, there is a gap of a fraction of a second. That happens when the shared app starts or stops helper processes (Discord does this when a call starts), when you change the app, microphone or buffer size, when a microphone is plugged or unplugged, and after sleep.
- No automatic updates. To update, install the newer pkg over the old one.
- The delay is designed to be about 10 to 12 ms at the default buffer size. The first measurements on a real Mac are part of the hands-on test in [docs/TESTING.md](docs/TESTING.md).

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
cmake -S driver -B build/driver-tests
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
| Driver and engine against the real Core Audio, with test devices | `integration.yml`, which calls `scripts/ci/integration.sh` | CI only |
| Ten-minute soak at 64 and 128 frames | `soak.yml` | CI only |
| The installer: lint, a pkg from stand-in bundles, install, diagnose, uninstall | `packaging.yml` | CI only |
| Everything that needs a person, a microphone and Discord | [docs/TESTING.md](docs/TESTING.md) | A real Mac |

`duettectl` is also installed with the pkg, at `/Library/Application Support/Duette/duettectl`. Its commands are listed in [tools/duettectl/README.md](tools/duettectl/README.md).

### Contributing and releasing

Commits are one Conventional Commits line with no body. PRs are squash-merged, and the PR title is what [release-please](https://github.com/googleapis/release-please) reads, so write it as `feat:`, `fix:` or `docs:`, and put `!` after the type for a breaking change. Don't edit `version.txt` or `CHANGELOG.md` by hand.

release-please keeps one release PR open. Merging it tags the version, creates the GitHub release (a pre-release while the version starts with `0.`), and starts the signed, notarized build that attaches the pkg, `uninstall.sh`, `TESTING.md` and `SHA256SUMS`. The one-time setup and the details are in [docs/RELEASING.md](docs/RELEASING.md).

## License

Duette is free software under the [GNU General Public License v3.0](LICENSE).
