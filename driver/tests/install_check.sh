#!/usr/bin/env bash
# CI install check for the HAL plug-in, run on the macOS runner after scripts/ci/build-driver.sh.
#
#  1. Install build/out/Duette.driver with scripts/install.sh (restarts coreaudiod).
#  2. system_profiler lists "Duette" and not "Duette Sink".
#  3. duette-driver-probe check: properties, custom properties, self-test tone, input clients,
#     loopback through the sink, shared clock.
#  4. Install build/test-out/Duette.driver: the test devices appear and behave.
#  5. scripts/uninstall.sh removes it again.
#
# GitHub's macos-15 runners load an ad-hoc signed plug-in after `killall coreaudiod` (spike S3),
# so a failure here is a real failure.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
probe=$repo_root/build/test-out/duette-driver-probe

for f in build/out/Duette.driver build/test-out/Duette.driver "$probe"; do
  if [ ! -e "$f" ]; then
    echo "install_check.sh: $f is missing; run scripts/ci/build-driver.sh first" >&2
    exit 1
  fi
done

failed=0
fail() {
  echo "::error::$*"
  failed=1
}

dump_log() {
  echo "::group::driver log (last 10 minutes)"
  /usr/bin/log show --last 10m --info --debug \
    --predicate 'subsystem == "me.roboroads.duette.driver" AND category == "driver"' 2>/dev/null |
    tail -n 200 || true
  echo "::endgroup::"
}

cleanup() {
  dump_log
  sudo bash "$repo_root/scripts/uninstall.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

audio_devices() {
  # Device names are the lines that end in a colon, indented 8 spaces, under "Devices:".
  system_profiler SPAudioDataType 2>/dev/null | sed -n 's/^        \([^ ].*\):$/\1/p'
}

wait_for_device_name() { # name, seconds
  local _
  for _ in $(seq 1 "$2"); do
    if audio_devices | grep -Fxq "$1"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "::group::install build/out/Duette.driver"
sudo bash scripts/install.sh --driver build/out/Duette.driver --no-app
echo "::endgroup::"

echo "::group::system_profiler SPAudioDataType"
wait_for_device_name Duette 30 || true
devices=$(audio_devices)
echo "$devices"
echo "::endgroup::"
if echo "$devices" | grep -Fxq Duette; then
  echo "PASS system_profiler lists Duette"
else
  fail "system_profiler does not list Duette"
fi
if echo "$devices" | grep -Fq 'Duette Sink'; then
  fail "system_profiler lists Duette Sink, which should be hidden"
else
  echo "PASS system_profiler does not list Duette Sink"
fi
if echo "$devices" | grep -Fq 'Duette Test'; then
  fail "the shippable plug-in publishes test devices"
fi

echo "::group::duette-driver-probe check"
"$probe" check || fail "duette-driver-probe check failed"
echo "::endgroup::"

echo "::group::install build/test-out/Duette.driver (test devices)"
sudo bash scripts/install.sh --driver build/test-out/Duette.driver --no-app
echo "::endgroup::"
wait_for_device_name 'Duette Test Speaker' 30 || true
devices=$(audio_devices)
echo "$devices"
for name in 'Duette Test Mic' 'Duette Test Speaker'; do
  if echo "$devices" | grep -Fxq "$name"; then
    echo "PASS system_profiler lists $name"
  else
    fail "system_profiler does not list $name"
  fi
done

echo "::group::duette-driver-probe test-devices"
"$probe" test-devices || fail "duette-driver-probe test-devices failed"
echo "::endgroup::"

echo "::group::uninstall"
sudo bash scripts/uninstall.sh
"$probe" absent || fail "Duette is still published after uninstall.sh"
echo "::endgroup::"

if [ "$failed" -ne 0 ]; then
  echo "install check failed"
  exit 1
fi
echo "install check passed"
