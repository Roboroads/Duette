#!/usr/bin/env bash
# Build and test duettectl (tools/duettectl). macOS only.
#
# Steps: `swift test` (argument parsing, WAV files, the FFT tone checker, the soak plan),
# then a release build, then a smoke run of the binary that needs no audio device.
#
# Product:
#   build/out/duettectl   Release, arm64, ad-hoc signed
#
# Environment:
#   DUETTECTL_BUILD_DIR   where the build trees go (default: <repo>/build/cli)
#   DUETTECTL_SKIP_TESTS  set to 1 to skip `swift test` (integration.sh does, to save time)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
package=$repo_root/tools/duettectl
build_root=${DUETTECTL_BUILD_DIR:-$repo_root/build/cli}
out_dir=$repo_root/build/out

if [ "$(uname -s)" != Darwin ]; then
  echo "build-cli.sh: duettectl needs macOS and its SDK" >&2
  exit 2
fi

swift --version

if [ "${DUETTECTL_SKIP_TESTS:-0}" != 1 ]; then
  echo "==> duettectl: tests"
  swift test --package-path "$package" --scratch-path "$build_root/debug"
fi

echo "==> duettectl: release build"
swift build --package-path "$package" --scratch-path "$build_root/release" -c release --arch arm64
bin_dir=$(swift build --package-path "$package" --scratch-path "$build_root/release" -c release --arch arm64 --show-bin-path)

mkdir -p "$out_dir"
rm -f "$out_dir/duettectl"
cp "$bin_dir/duettectl" "$out_dir/duettectl"
codesign --force --sign - --timestamp=none "$out_dir/duettectl"
archs=$(lipo -archs "$out_dir/duettectl")
if [ "$archs" != arm64 ]; then
  echo "build-cli.sh: build/out/duettectl is '$archs', want arm64" >&2
  exit 1
fi

echo "==> duettectl: smoke run"
smoke=$(mktemp -d "${TMPDIR:-/tmp}/duettectl-smoke.XXXXXX")
trap 'rm -rf "$smoke"' EXIT
"$out_dir/duettectl" --help >/dev/null
"$out_dir/duettectl" make-tone --out "$smoke/tone.wav" --hz 440 --dbfs -12 --rate 44100 --seconds 2
"$out_dir/duettectl" analyze "$smoke/tone.wav" --expect '440@-12,1000<-60'
if "$out_dir/duettectl" analyze "$smoke/tone.wav" --expect '440@-6' >/dev/null; then
  echo "build-cli.sh: analyze passed a tone at the wrong level" >&2
  exit 1
fi

echo "==> duettectl built: build/out/duettectl"
