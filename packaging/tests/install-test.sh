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

NOTE_TEXT="Login Items & Extensions"
MARKER="/tmp/duette-stub-unregister"
work_dir="$(mktemp -d)"
cp "$SUPPORT/uninstall.sh" "$work_dir/uninstall.sh"

# The uninstaller asks the app to take itself out of Login Items, as the person at the console
# (the stub app, built by make-stub-bundles.sh, leaves a line in $MARKER when it is asked). With
# nobody at the console it cannot, and has to say how to do it by hand.
console="$(stat -f%Su /dev/console 2> /dev/null || true)"
console_user_present=0
case "$console" in
  '' | root | loginwindow) ;;
  *)
    # The same chain the uninstaller uses to reach the person's login session.
    console_uid="$(id -u "$console")"
    if sudo /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console" /usr/bin/true; then
      console_user_present=1
    else
      echo "::notice::Cannot reach the login session of '$console' here, so the uninstaller has to fall back to its note."
    fi
    ;;
esac
echo "--- uninstaller (console user: '${console}', login session reachable: ${console_user_present})"
sudo rm -f "$MARKER"
sudo "$SUPPORT/uninstall.sh" 2>&1 | tee "$work_dir/uninstall.out"
check_gone "$APP"
check_gone "$DRIVER"
check_gone "$SUPPORT"
if pkgutil --pkg-info me.roboroads.duette.pkg > /dev/null 2>&1; then fail "receipt is still there"; else pass "receipt forgotten"; fi

echo "--- the login item"
if [ "$console_user_present" -eq 1 ]; then
  if grep -qx -- '--unregister-login-item' "$MARKER" 2> /dev/null; then pass "the app was run with --unregister-login-item"; else fail "the app was never asked to remove its login item"; fi
  if grep -q 'Removed Duette from Login Items.' "$work_dir/uninstall.out"; then pass "the app's answer is in the uninstaller output"; else fail "no answer from the app in the output"; fi
  if grep -q "$NOTE_TEXT" "$work_dir/uninstall.out"; then fail "the by-hand note was printed although the app did it"; else pass "no by-hand note needed"; fi
else
  if [ -e "$MARKER" ]; then fail "the app was run with nobody at the console"; else pass "the app was not run with nobody at the console"; fi
  if grep -q "$NOTE_TEXT" "$work_dir/uninstall.out"; then pass "the note about Login Items & Extensions was printed"; else fail "no note about removing the login item by hand"; fi
fi

echo "--- the uninstaller on a Mac where Duette is already gone"
sudo rm -f "$MARKER"
if sudo /bin/bash "$work_dir/uninstall.sh" 2>&1 | tee "$work_dir/second.out"; then pass "second run succeeds"; else fail "second run failed"; fi
for path in "$APP" "$DRIVER" "$SUPPORT"; do
  if grep -qF "Not installed: $path" "$work_dir/second.out"; then pass "second run says 'Not installed: $path'"; else fail "second run does not mention $path"; fi
done
if grep -q "$NOTE_TEXT" "$work_dir/second.out"; then pass "second run points at Login Items & Extensions (there is no app left to ask)"; else fail "second run has no note about the login item"; fi
if [ -e "$MARKER" ]; then fail "the second run started an app that is not there"; else pass "no app was run the second time"; fi
if grep -q '^Duette is removed\.$' "$work_dir/second.out"; then pass "second run ends with 'Duette is removed.'"; else fail "second run does not end in 'Duette is removed.'"; fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
