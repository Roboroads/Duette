#!/usr/bin/env bash
# Remove Duette from this Mac: the app, the HAL plug-in and its support files. Run with sudo.
#
# Usage: sudo uninstall.sh [--no-restart]
#   --no-restart   don't restart coreaudiod (the plug-in unloads on its next start)
#
# The installer puts a copy at "/Library/Application Support/Duette/uninstall.sh".
set -euo pipefail

restart=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) restart=no; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "uninstall.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Darwin ]; then
  echo "uninstall.sh: Duette runs only on macOS" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh: run it with sudo" >&2
  exit 1
fi

echo "==> quitting Duette"
pkill -x Duette 2>/dev/null || true

for path in /Applications/Duette.app /Library/Audio/Plug-Ins/HAL/Duette.driver \
  "/Library/Application Support/Duette"; do
  if [ -e "$path" ]; then
    echo "==> removing $path"
    rm -rf "$path"
  fi
done

# Receipts from the .pkg installer, if it was used.
for pkg in $(pkgutil --pkgs='me\.roboroads\.duette.*' 2>/dev/null || true); do
  echo "==> forgetting package $pkg"
  pkgutil --forget "$pkg" >/dev/null || true
done

if [ "$restart" = yes ]; then
  echo "==> restarting coreaudiod"
  killall coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod || true
  for _ in $(seq 1 40); do
    pgrep -x coreaudiod >/dev/null && break
    sleep 0.25
  done
fi
echo "==> Duette removed"
