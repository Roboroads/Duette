#!/usr/bin/env bash
# Asserts that a built installer has the expected contents. macOS only.
#
#   packaging/tests/check-pkg.sh build/release/Duette-0.1.0.pkg
#
# Checks the payload paths, the install scripts, the package identifier and
# version, and the installer window settings.
set -euo pipefail
cd "$(dirname "$0")/../.."

pkg="${1:-}"
[ -f "$pkg" ] || { echo "usage: check-pkg.sh <pkg>" >&2; exit 2; }

version="$(tr -d '[:space:]' < version.txt)"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

echo "--- pkgutil --check-signature"
pkgutil --check-signature "$pkg" || true

echo "--- pkgutil --payload-files"
payload="$(pkgutil --payload-files "$pkg" | sed -e 's|^\./||' -e '/^\.$/d')"
printf '%s\n' "$payload"

expected=(
  "Applications/Duette.app/Contents/Info.plist"
  "Applications/Duette.app/Contents/MacOS/Duette"
  "Library/Audio/Plug-Ins/HAL/Duette.driver/Contents/Info.plist"
  "Library/Audio/Plug-Ins/HAL/Duette.driver/Contents/MacOS/Duette"
  "Library/Application Support/Duette/uninstall.sh"
  "Library/Application Support/Duette/duette-diagnose.sh"
)
for path in "${expected[@]}"; do
  if grep -Fxq -- "$path" <<< "$payload"; then pass "payload has $path"; else fail "payload is missing $path"; fi
done
# Nothing outside the three install locations.
unexpected="$(grep -Ev '^(Applications|Library)(/|$)' <<< "$payload" || true)"
if [ -n "$unexpected" ]; then fail "unexpected payload paths: $unexpected"; else pass "payload stays under Applications and Library"; fi

echo "--- pkgutil --expand-full"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgutil --expand-full "$pkg" "$work/expanded"
find "$work/expanded" -maxdepth 2 | sed "s|$work/expanded|.|"

component="$(find "$work/expanded" -maxdepth 1 -name '*.pkg' | head -n 1)"
if [ -z "$component" ]; then
  fail "no component package inside the pkg"
else
  for script in preinstall postinstall; do
    if [ -x "$component/Scripts/$script" ]; then pass "$script is present and executable"; else fail "$script is missing or not executable"; fi
  done
  info="$component/PackageInfo"
  if grep -q 'identifier="me.roboroads.duette.pkg"' "$info"; then pass "package identifier is me.roboroads.duette.pkg"; else fail "wrong package identifier"; fi
  if grep -q "version=\"$version\"" "$info"; then pass "package version is $version"; else fail "package version is not $version"; fi
  if grep -q 'install-location="/"' "$info"; then pass "install location is /"; else fail "install location is not /"; fi
  mode="$(stat -f '%Lp' "$component/Payload/Library/Application Support/Duette/uninstall.sh")"
  if [ "$mode" = "755" ]; then pass "uninstall.sh is mode 755"; else fail "uninstall.sh is mode $mode"; fi
fi

distribution="$work/expanded/Distribution"
if [ -f "$distribution" ]; then
  if grep -q 'hostArchitectures="arm64"' "$distribution"; then pass "installer requires arm64"; else fail "Distribution has no arm64 requirement"; fi
  if grep -q 'min="14.2"' "$distribution"; then pass "installer requires macOS 14.2"; else fail "Distribution has no macOS 14.2 requirement"; fi
  if grep -q 'rootVolumeOnly="true"' "$distribution"; then pass "installer is limited to the startup disk"; else fail "Distribution is not limited to the startup disk"; fi
else
  fail "no Distribution file"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
