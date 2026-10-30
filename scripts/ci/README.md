# CI scripts

`.github/workflows/ci.yml` calls these scripts. Each one is optional: the workflow runs it only if the file exists, so adding a script is all it takes to turn its step on.

| Script | Job | Owns |
|---|---|---|
| `test-core.sh` | `core-linux`, `macos-build` | Build and test `core/` (CMake and ctest, plus sanitizer runs). |
| `build-driver.sh` | `macos-build` | Build `Duette.driver` from `driver/`. |
| `build-kit.sh` | `macos-build` | `swift build` and `swift test` for `Packages/DuetteKit`. |
| `build-app.sh` | `macos-build` | Generate the Xcode project with XcodeGen, then `xcodebuild build test` for the app. |
| `build-cli.sh` | `macos-build` | Build and test `tools/duettectl`. |

`integration.sh` is not listed here because it is not part of `ci.yml`. It runs from its own workflow.

## Rules for a script

- Run from the repo root and `cd` there first if you need relative paths: `cd "$(dirname "$0")/../.."`.
- Start with `set -euo pipefail` and exit non-zero on any failure. Don't swallow errors.
- Don't assume anything is preinstalled beyond what `ubuntu-latest` and `macos-15` ship. Install what you need inside the script (`brew install xcodegen`).
- `test-core.sh` must also work on Linux. The other four are macOS-only.
- Scripts run on a clean checkout and must not depend on a previous script having run.

## Output contract

Build scripts write their products to `build/out/` (git-ignored) under exactly these names:

| Product | Written by |
|---|---|
| `build/out/Duette.driver` | `build-driver.sh` |
| `build/out/Duette.app` | `build-app.sh` |
| `build/out/duettectl` | `build-cli.sh` |

`macos-build` uploads everything under `build/out/` as the `duette-build` workflow artifact. Nothing is uploaded if the folder is missing or empty. Artifacts are zipped, so the executable bit is lost: run `chmod +x duettectl` after downloading one.

## Version

`version.txt` at the repo root holds the version, for example `0.1.0`. Read it with `tr -d '[:space:]' < version.txt`. Use it for `CFBundleShortVersionString` and use `GITHUB_RUN_NUMBER` (default `0` when unset) for `CFBundleVersion`. Never write to `version.txt`; release-please owns it.

## Adding a new CI script

1. Add `scripts/ci/<name>.sh` following the rules above.
2. Add a step to `macos-build` (or `core-linux`) in `ci.yml` guarded by `if: hashFiles('scripts/ci/<name>.sh') != ''`.
3. Add a row to the table in this file.
