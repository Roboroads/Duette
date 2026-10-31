#!/usr/bin/env bash
# Build and test the DuetteKit SwiftPM package (Packages/DuetteKit). macOS only.
#
# Steps: debug build, `swift test`, the engine tests again under ThreadSanitizer, then a release
# build so optimizer-only problems show up too.
# Build trees go to build/kit (git-ignored), never into the package folder.
#
# Environment:
#   DUETTE_KIT_BUILD_DIR  where the build trees go (default: <repo>/build/kit)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
package=$repo_root/Packages/DuetteKit
build_root=${DUETTE_KIT_BUILD_DIR:-$repo_root/build/kit}

if [ "$(uname -s)" != Darwin ]; then
  echo "build-kit.sh: DuetteKit needs macOS and its SDK" >&2
  exit 2
fi

swift --version

echo "==> DuetteKit: debug build"
swift build --package-path "$package" --scratch-path "$build_root/debug"

echo "==> DuetteKit: tests"
swift test --package-path "$package" --scratch-path "$build_root/debug"

# The engine's IOProc and its control functions share state through atomics only; ThreadSanitizer
# checks that while a test runs the IOProc on one thread and changes parameters on another.
echo "==> DuetteKit: engine tests under ThreadSanitizer"
swift test --package-path "$package" --scratch-path "$build_root/tsan" --sanitize=thread \
  --filter DuetteEngineTests

echo "==> DuetteKit: release build"
swift build --package-path "$package" --scratch-path "$build_root/release" -c release

echo "==> DuetteKit passed"
