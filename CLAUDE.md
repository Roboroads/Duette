# Duette

## AI attribution
No AI attribution anywhere in the repo. No `Co-Authored-By`, no "Generated with Claude Code", nothing naming an AI in commits, PR bodies, or files. Drop every attribution line a tool or harness suggests. Commits are a single Conventional Commits line with no body or trailers.

## Pull request titles
PRs are squash-merged, so the PR title becomes the commit release-please reads. A PR that breaks the public API (a removed or renamed class, method, constructor or field, or changed wire output) must mark it with `!` after the type: `feat!: ...`, `fix!: ...`, `refactor!: ...`. Without the `!`, release-please treats it as non-breaking and picks the wrong version bump.

## Project conventions
Duette is a macOS menu bar app (Apple Silicon, macOS 14.2+) that mixes one app's audio and a microphone into a virtual input device called "Duette". The bundle ID prefix is `me.roboroads.duette`.

### Repo layout
Some of these folders arrive in later steps; put new code where it belongs.

| Path | What lives there |
|---|---|
| `core/` | Header-only C++17 DSP library. No Apple dependencies, so it builds and tests on Linux. |
| `driver/` | The HAL plug-in (`Duette.driver`), C++17 on libASPL, built with CMake. |
| `Packages/DuetteKit/` | Local SwiftPM package: `DuetteEngine` (real-time C++ with a C header) and `DuetteAudio` (Swift Core Audio wrappers and the engine state machine). |
| `app/` | The SwiftUI menu bar app. The Xcode project is generated from `app/project.yml` with XcodeGen; never commit an `.xcodeproj`. |
| `tools/duettectl/` | Swift CLI on DuetteKit for headless CI checks. |
| `packaging/` | pkg resources: distribution file and the pre/postinstall scripts. |
| `scripts/` | Dev and release scripts (install, uninstall, sign, notarize, diagnose). |
| `scripts/ci/` | The entry points CI calls. See `scripts/ci/README.md`. |
| `spikes/` | Throwaway experiments. Nothing in the product depends on them. |
| `docs/` | Longer docs, for example `docs/SIGNING.md`. |
| `.github/workflows/` | CI and release workflows. |
| `version.txt` | The single source of the version. |

### CI contract and artifacts
CI calls fixed scripts from the repo root: `scripts/ci/test-core.sh`, `build-driver.sh`, `build-kit.sh`, `build-app.sh` and `build-cli.sh`. `.github/workflows/ci.yml` runs each one only if the file exists, so a step adds its script and CI picks it up with no workflow edit.

Build scripts leave their products in `build/out/` (git-ignored), under these exact names:
- `build/out/Duette.driver`
- `build/out/Duette.app`
- `build/out/duettectl`

Everything in `build/out/` is a shippable build: Release configuration, arm64, unsigned or ad-hoc signed, and built without the test devices. Debug builds and test-device variants go to `build/test-out/` instead, so packaging never picks them up. Each script runs `mkdir -p build/out` and replaces any existing product of the same name.

Packaging and release consume only the `build/out/` paths. Do not rename them.

### Versioning
`version.txt` is the only place the version lives. Builds read it for `CFBundleShortVersionString` (app and driver) and the pkg version. `CFBundleVersion` is the CI run number. release-please owns the file and `CHANGELOG.md`, so never edit either by hand or bump a version in a PR.

### Real-time rules
Code that runs on a Core Audio I/O thread (the app's IOProc and the plug-in's read/write callbacks) is C++17 and must not:
- allocate or free memory;
- take locks or wait on anything;
- log, or call into Objective-C or Swift;
- make system calls that can block.

Share state with other threads through relaxed or acquire/release atomics only. Everything else (UI, device and process enumeration, the tap and aggregate lifecycle, persistence) is Swift.

### CI is the compiler for Apple code
The dev container is Linux with clang and cmake but no Swift and no macOS SDK. Swift, Objective-C, libASPL and anything that includes a CoreAudio header can only be compiled by the macOS jobs in GitHub Actions. CI runs on pull requests and on pushes to `main` only, so open a draft PR first, then push often, and read the run's logs before guessing at a fix. Keep `core/` free of Apple headers so it stays testable on Linux.
