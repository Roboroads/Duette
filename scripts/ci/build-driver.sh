#!/usr/bin/env bash
# Build the HAL plug-in (driver/) and run its unit tests. macOS only.
#
# Products:
#   build/out/Duette.driver             shippable: Release, arm64, ad-hoc signed, no test devices
#   build/test-out/Duette.driver        the same with DUETTE_TEST_DEVICES=ON (CI only)
#   build/test-out/duette-driver-probe  CoreAudio client the CI install check runs
#
# Environment:
#   GITHUB_RUN_NUMBER   CFBundleVersion (default 0)
#   CMAKE_GENERATOR     generator to use (default: Ninja if installed, else CMake's choice)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)

if [ "$(uname -s)" != Darwin ]; then
  echo "build-driver.sh: the plug-in builds only on macOS" >&2
  exit 1
fi

version=$(tr -d '[:space:]' < version.txt)
build_number=${GITHUB_RUN_NUMBER:-0}
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
if [ -z "${CMAKE_GENERATOR:-}" ] && command -v ninja >/dev/null 2>&1; then
  export CMAKE_GENERATOR=Ninja
fi

release_dir=$repo_root/build/driver-release
testdev_dir=$repo_root/build/driver-testdevices
out_dir=$repo_root/build/out
test_out_dir=$repo_root/build/test-out
mkdir -p "$out_dir" "$test_out_dir"

configure() { # build dir, extra args...
  local dir=$1
  shift
  cmake -S "$repo_root/driver" -B "$dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 \
    -DDUETTE_BUILD_NUMBER="$build_number" \
    -DDUETTE_WARNINGS_AS_ERRORS=ON \
    "$@"
}

echo "==> driver: release build with unit tests and probe ($release_dir)"
configure "$release_dir" -DDUETTE_TEST_DEVICES=OFF -DDUETTE_DRIVER_BUILD_TESTS=ON \
  -DDUETTE_DRIVER_BUILD_PROBE=ON
cmake --build "$release_dir" --parallel "$jobs"

echo "==> driver: unit tests"
ctest --test-dir "$release_dir" --output-on-failure --no-tests=error --parallel "$jobs"

echo "==> driver: build with test devices ($testdev_dir)"
configure "$testdev_dir" -DDUETTE_TEST_DEVICES=ON -DDUETTE_DRIVER_BUILD_TESTS=OFF \
  -DDUETTE_DRIVER_BUILD_PROBE=OFF
cmake --build "$testdev_dir" --parallel "$jobs" --target DuetteDriver

# Copy a fresh bundle into place, sign it ad hoc and check it.
publish() { # source bundle, destination dir, "ship" or "test"
  local src=$1 dest=$2/Duette.driver kind=$3
  rm -rf "$dest"
  cp -R "$src" "$dest"
  codesign --force --sign - --timestamp=none "$dest"

  local plist=$dest/Contents/Info.plist binary=$dest/Contents/MacOS/Duette
  plutil -lint "$plist"
  local got_version got_build got_id
  got_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  got_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
  got_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
  if [ "$got_version" != "$version" ]; then
    echo "build-driver.sh: CFBundleShortVersionString is '$got_version', version.txt says '$version'" >&2
    exit 1
  fi
  if [ "$got_build" != "$build_number" ]; then
    echo "build-driver.sh: CFBundleVersion is '$got_build', want '$build_number'" >&2
    exit 1
  fi
  if [ "$got_id" != me.roboroads.duette.driver ]; then
    echo "build-driver.sh: CFBundleIdentifier is '$got_id'" >&2
    exit 1
  fi
  if [ "$(lipo -archs "$binary")" != arm64 ]; then
    echo "build-driver.sh: $binary is '$(lipo -archs "$binary")', want arm64" >&2
    exit 1
  fi
  if ! nm -gU "$binary" | grep -q ' _DuetteDriverEntryPoint$'; then
    echo "build-driver.sh: $binary does not export DuetteDriverEntryPoint" >&2
    exit 1
  fi
  # Test devices must never reach a shippable bundle, and must be in the test one.
  if strings "$binary" | grep -q 'Duette Test Mic'; then
    [ "$kind" = test ] || { echo "build-driver.sh: $dest contains the test devices" >&2; exit 1; }
  else
    [ "$kind" = ship ] || { echo "build-driver.sh: $dest lacks the test devices" >&2; exit 1; }
  fi
  codesign --verify --strict --verbose=2 "$dest"
  codesign -dv "$dest" 2>&1
  echo "==> $dest: $got_id $got_version ($got_build), $kind"
}

publish "$release_dir/Duette.driver" "$out_dir" ship
publish "$testdev_dir/Duette.driver" "$test_out_dir" test

rm -f "$test_out_dir/duette-driver-probe"
cp "$release_dir/duette-driver-probe" "$test_out_dir/duette-driver-probe"
codesign --force --sign - --timestamp=none "$test_out_dir/duette-driver-probe"

echo "==> driver built: build/out/Duette.driver, build/test-out/Duette.driver, build/test-out/duette-driver-probe"
