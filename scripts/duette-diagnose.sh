#!/bin/bash
# Collects the information needed to debug Duette into one zip on the Desktop.
# Use it when the app will not open, so "Export Diagnostics..." is not available:
#
#   sudo "/Library/Application Support/Duette/duette-diagnose.sh"
#
# It also works without sudo. Then it reads whatever your own account can
# see, which is enough for most problems.
#
#   --out <dir>   write the zip there instead of onto the Desktop
#
# The zip holds the same files as the app's export, minus the engine
# statistics: diagnostics.json, system.log, codesign.txt, devices.txt and
# crash reports that mention Duette. Nothing is sent anywhere; you attach
# the zip to your report yourself.
#
# Runs on the bash 3.2 that ships with macOS.

APP="/Applications/Duette.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/Duette.driver"
SUPPORT="/Library/Application Support/Duette"
SCRIPT_VERSION="1"

OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      OUT_DIR="${2:-}"
      shift 2 || { echo "--out needs a folder" >&2; exit 2; }
      ;;
    -h | --help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# The person at the keyboard, even when this runs under sudo.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$(/usr/bin/id -un)"
fi
TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2> /dev/null | /usr/bin/awk '{print $2}')"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"
[ -n "$OUT_DIR" ] || OUT_DIR="$TARGET_HOME/Desktop"
/bin/mkdir -p "$OUT_DIR" || { echo "Cannot create $OUT_DIR" >&2; exit 1; }
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
NAME="Duette-Diagnostics-$STAMP"
WORK="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT
DIR="$WORK/$NAME"
/bin/mkdir -p "$DIR"

echo "Collecting diagnostics. This can take a minute."

# json_str <text>: a JSON string literal. Control characters are dropped, tabs
# and carriage returns become spaces, line breaks become \n.
json_str() {
  printf '%s' "$1" \
    | LC_ALL=C /usr/bin/tr -d '\000-\010\013\014\016-\037' \
    | LC_ALL=C /usr/bin/tr '\t\r' '  ' \
    | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | /usr/bin/awk 'BEGIN { printf "\"" } NR > 1 { printf "%s", "\\n" } { printf "%s", $0 } END { printf "\"" }'
}

plist_value() { # <plist> <key>
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2> /dev/null
}

bundle_version() { # <bundle>
  plist_value "$1/Contents/Info.plist" CFBundleShortVersionString
}

bundle_build() { # <bundle>
  plist_value "$1/Contents/Info.plist" CFBundleVersion
}

exists_json() { if [ -e "$1" ]; then echo true; else echo false; fi; }

app_running="false"
if /usr/bin/pgrep -f '/Duette\.app/Contents/MacOS/' > /dev/null 2>&1; then app_running="true"; fi

macos_version="$(/usr/bin/sw_vers -productVersion 2> /dev/null)"
macos_build="$(/usr/bin/sw_vers -buildVersion 2> /dev/null)"
hw_model="$(/usr/sbin/sysctl -n hw.model 2> /dev/null)"
arch="$(/usr/bin/uname -m)"

# system_profiler can print JSON; fall back to null if it fails.
audio_json="$(/usr/sbin/system_profiler SPAudioDataType -json 2> /dev/null)"
[ -n "$audio_json" ] || audio_json="null"

{
  echo "{"
  echo "  \"schema\": \"duette-diagnose-sh/$SCRIPT_VERSION\","
  echo "  \"generatedAt\": $(json_str "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"),"
  echo "  \"runAsRoot\": $([ "$(/usr/bin/id -u)" -eq 0 ] && echo true || echo false),"
  echo "  \"user\": $(json_str "$TARGET_USER"),"
  echo "  \"macOS\": { \"version\": $(json_str "$macos_version"), \"build\": $(json_str "$macos_build"), \"arch\": $(json_str "$arch"), \"hardwareModel\": $(json_str "$hw_model") },"
  echo "  \"app\": { \"installed\": $(exists_json "$APP"), \"running\": $app_running, \"version\": $(json_str "$(bundle_version "$APP")"), \"build\": $(json_str "$(bundle_build "$APP")") },"
  echo "  \"driver\": { \"installed\": $(exists_json "$DRIVER"), \"version\": $(json_str "$(bundle_version "$DRIVER")"), \"build\": $(json_str "$(bundle_build "$DRIVER")") },"
  echo "  \"supportFolderInstalled\": $(exists_json "$SUPPORT"),"
  echo "  \"receipts\": $(json_str "$(/usr/sbin/pkgutil --pkgs='me\.roboroads\.duette' 2> /dev/null)"),"
  echo "  \"audioDevices\": $audio_json,"
  echo "  \"engine\": null"
  echo "}"
} > "$DIR/diagnostics.json"

# Signature and Gatekeeper state of the installed bundles.
{
  for item in "$APP" "$DRIVER"; do
    echo "=== $item"
    if [ -e "$item" ]; then
      echo "--- codesign -dvv"
      /usr/bin/codesign -dvv "$item" 2>&1
      echo "--- codesign --verify --deep --strict"
      /usr/bin/codesign --verify --deep --strict --verbose=2 "$item" 2>&1
      echo "--- spctl -a -vv"
      /usr/sbin/spctl -a -vv "$item" 2>&1
    else
      echo "not installed"
    fi
    echo
  done
} > "$DIR/codesign.txt"

# What the system thinks is installed and loaded.
{
  echo "--- sw_vers"
  /usr/bin/sw_vers 2>&1
  echo
  echo "--- HAL plug-ins"
  /bin/ls -la /Library/Audio/Plug-Ins/HAL/ 2>&1
  echo
  echo "--- support folder"
  /bin/ls -la "$SUPPORT" 2>&1
  echo
  echo "--- Duette processes"
  /usr/bin/pgrep -lf 'Duette' 2>&1
  echo
  echo "--- installer receipts"
  for id in $(/usr/sbin/pkgutil --pkgs='me\.roboroads\.duette' 2> /dev/null); do
    /usr/sbin/pkgutil --pkg-info "$id" 2>&1
    echo
  done
  echo "--- audio devices (system_profiler)"
  /usr/sbin/system_profiler SPAudioDataType 2>&1
  if [ -x "$SUPPORT/duettectl" ]; then
    echo
    echo "--- duettectl list"
    "$SUPPORT/duettectl" list 2>&1
  fi
} > "$DIR/devices.txt"

# Unified log: Duette's own messages and what coreaudiod said about Duette.
/usr/bin/log show --last 30m --style compact \
  --predicate 'subsystem BEGINSWITH "me.roboroads.duette"' > "$DIR/system.log" 2>&1
/usr/bin/log show --last 30m --style compact \
  --predicate 'process == "coreaudiod" AND eventMessage CONTAINS[c] "duette"' > "$DIR/coreaudiod.log" 2>&1

# Crash and hang reports from the last week that name Duette or coreaudiod.
/bin/mkdir -p "$DIR/reports"
for reports in "$TARGET_HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  [ -d "$reports" ] || continue
  /usr/bin/find "$reports" -maxdepth 1 -type f -mtime -7 \( -iname 'Duette*' -o -iname 'coreaudiod*' \) \
    -exec /bin/cp {} "$DIR/reports/" \; 2> /dev/null
done

ZIP="$OUT_DIR/$NAME.zip"
(cd "$WORK" && /usr/bin/zip -qr "$ZIP" "$NAME") || { echo "Could not create $ZIP" >&2; exit 1; }
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  /usr/sbin/chown "$TARGET_USER" "$ZIP" 2> /dev/null
fi

echo
echo "Done. Send this file with your report:"
echo "  $ZIP"
exit 0
