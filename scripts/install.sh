#!/usr/bin/env bash
# Install a locally built Duette: the HAL plug-in, and the app when there is one. Run with sudo.
#
# Usage: sudo scripts/install.sh [--driver PATH] [--app PATH] [--no-app] [--no-restart]
#   --driver PATH   Duette.driver to install (default: build/out/Duette.driver)
#   --app PATH      Duette.app to install (default: build/out/Duette.app, skipped if missing)
#   --no-app        install only the plug-in
#   --no-restart    don't restart coreaudiod (the plug-in loads on its next start)
#
# coreaudiod loads plug-ins only when it starts, so this restarts it. Audio stops for a moment in
# every app.
set -euo pipefail

HAL_DIR=/Library/Audio/Plug-Ins/HAL
APP_DIR=/Applications

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
driver=$repo_root/build/out/Duette.driver
app=$repo_root/build/out/Duette.app
want_app=auto
restart=yes

while [ $# -gt 0 ]; do
  case "$1" in
    --driver) driver=${2:?--driver needs a path}; shift 2 ;;
    --app) app=${2:?--app needs a path}; want_app=yes; shift 2 ;;
    --no-app) want_app=no; shift ;;
    --no-restart) restart=no; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Darwin ]; then
  echo "install.sh: Duette installs only on macOS" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh: run it with sudo" >&2
  exit 1
fi
if [ ! -f "$driver/Contents/Info.plist" ]; then
  echo "install.sh: no plug-in at $driver (build it with scripts/ci/build-driver.sh)" >&2
  exit 1
fi

restart_coreaudiod() {
  echo "==> restarting coreaudiod"
  # launchd starts it again at once. kickstart is the fallback for systems where killall is
  # refused.
  killall coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod || true
  for _ in $(seq 1 40); do
    if pgrep -x coreaudiod >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "install.sh: coreaudiod did not come back; it starts on the next audio request" >&2
}

echo "==> installing $(basename "$driver") into $HAL_DIR"
mkdir -p "$HAL_DIR"
rm -rf "$HAL_DIR/Duette.driver"
ditto "$driver" "$HAL_DIR/Duette.driver"
chown -R root:wheel "$HAL_DIR/Duette.driver"
chmod -R go-w "$HAL_DIR/Duette.driver"

if [ "$want_app" != no ]; then
  if [ -d "$app" ]; then
    echo "==> installing $(basename "$app") into $APP_DIR"
    pkill -x Duette 2>/dev/null || true
    rm -rf "$APP_DIR/Duette.app"
    ditto "$app" "$APP_DIR/Duette.app"
    chown -R root:wheel "$APP_DIR/Duette.app"
  elif [ "$want_app" = yes ]; then
    echo "install.sh: no app at $app" >&2
    exit 1
  else
    echo "==> no app at $app, installing the plug-in only"
  fi
fi

if [ "$restart" = yes ]; then
  restart_coreaudiod
fi
echo "==> installed"
