#!/usr/bin/env bash
# Installs the pkg on this Mac, checks the result, runs the uninstaller and checks that
# everything is gone. Meant for a throwaway CI runner: it uses sudo, restarts coreaudiod
# and removes /Applications/Duette.app.
#
#   packaging/tests/install-test.sh build/release/Duette-0.1.0.pkg
set -euo pipefail
cd "$(dirname "$0")/../.."

pkg="${1:-}"
[ -f "$pkg" ] || { echo "usage: install-test.sh <pkg>" >&2; exit 2; }

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
check_exists() { if [ -e "$1" ]; then pass "exists: $1"; else fail "missing: $1"; fi; }
check_gone() { if [ ! -e "$1" ]; then pass "gone: $1"; else fail "still there: $1"; fi; }

APP="/Applications/Duette.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/Duette.driver"
SUPPORT="/Library/Application Support/Duette"

echo "--- installer"
sudo installer -verbose -pkg "$pkg" -target /

check_exists "$APP/Contents/MacOS/Duette"
check_exists "$DRIVER/Contents/MacOS/Duette"
check_exists "$SUPPORT/uninstall.sh"
check_exists "$SUPPORT/duette-diagnose.sh"
check_exists "$SUPPORT/duettectl"

owner="$(stat -f '%Su:%Sg' "$DRIVER")"
if [ "$owner" = "root:wheel" ]; then pass "driver is owned by root:wheel"; else fail "driver is owned by $owner"; fi

if pkgutil --pkg-info me.roboroads.duette.pkg; then pass "receipt me.roboroads.duette.pkg exists"; else fail "no installer receipt"; fi

echo "--- the signatures survived the install"
if codesign --verify --deep --strict --verbose=2 "$APP"; then pass "app signature verifies"; else fail "app signature is broken"; fi
if codesign --verify --deep --strict --verbose=2 "$DRIVER"; then pass "driver signature verifies"; else fail "driver signature is broken"; fi

echo "--- install log (our scripts)"
grep -E 'Restarting coreaudiod|Opening Duette|Nobody is logged in|Warning:' /var/log/install.log | tail -n 10 || true

echo "--- a second install over the first (upgrade path)"
sudo installer -pkg "$pkg" -target /
check_exists "$APP/Contents/MacOS/Duette"

echo "--- the diagnose script that was installed"
diag_dir="$(mktemp -d)"
sudo "$SUPPORT/duette-diagnose.sh" --out "$diag_dir"
zip_file="$(find "$diag_dir" -name 'Duette-Diagnostics-*.zip' | head -n 1)"
if [ -n "$zip_file" ]; then
  pass "diagnostics zip written"
  unzip -l "$zip_file"
  unzip -p "$zip_file" '*/diagnostics.json' > "$diag_dir/diagnostics.json"
  if jq -e . "$diag_dir/diagnostics.json" > /dev/null; then pass "diagnostics.json is valid JSON"; else fail "diagnostics.json is not valid JSON"; fi
  for member in codesign.txt devices.txt system.log; do
    if unzip -l "$zip_file" | grep -q "/$member\$"; then pass "zip has $member"; else fail "zip lacks $member"; fi
  done
else
  fail "no diagnostics zip"
fi

echo "--- uninstaller"
sudo "$SUPPORT/uninstall.sh"
check_gone "$APP"
check_gone "$DRIVER"
check_gone "$SUPPORT"
if pkgutil --pkg-info me.roboroads.duette.pkg > /dev/null 2>&1; then fail "receipt is still there"; else pass "receipt forgotten"; fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
