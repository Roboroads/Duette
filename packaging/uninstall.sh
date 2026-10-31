#!/bin/bash
# Removes Duette from this Mac.
#
#   sudo "/Library/Application Support/Duette/uninstall.sh"
#
# Takes Duette out of Login Items, removes the app, the audio driver and the
# support folder, forgets the installer receipts and restarts the audio system.
# Your Duette settings in ~/Library/Preferences are left alone, so a later
# reinstall keeps them.
#
# The login item is the app's own: it registered itself for the person who
# switched "Open Duette when I log in" on, and only the app can take it out.
# So before the app is deleted it is run once, as the person at the console,
# with --unregister-login-item. If that does not work, the uninstall carries on
# and ends with a note on how to remove the entry by hand.
#
# This is the pkg's own copy. scripts/uninstall.sh (the dev-machine script)
# runs it, so a locally built install is removed the same way.
#
# Runs on the bash 3.2 that ships with macOS.

APP="/Applications/Duette.app"
APP_BIN="$APP/Contents/MacOS/Duette"
DRIVER="/Library/Audio/Plug-Ins/HAL/Duette.driver"
SUPPORT="/Library/Application Support/Duette"
APP_PATTERN='/Duette\.app/Contents/MacOS/'

console_user() {
  local user
  user="$(/usr/bin/stat -f%Su /dev/console 2> /dev/null)"
  case "$user" in
    '' | root | loginwindow) return 1 ;;
  esac
  echo "$user"
}

is_running() {
  /usr/bin/pgrep -f "$APP_PATTERN" > /dev/null 2>&1
}

quit_app() {
  is_running || return 0
  echo "Quitting Duette..."
  local user uid i=0
  if user="$(console_user)"; then
    uid="$(/usr/bin/id -u "$user" 2> /dev/null)"
    if [ -n "$uid" ]; then
      /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" \
        /usr/bin/osascript -e 'tell application id "me.roboroads.duette" to quit' > /dev/null 2>&1
    fi
  fi
  while [ "$i" -lt 10 ] && is_running; do
    /bin/sleep 1
    i=$((i + 1))
  done
  if is_running; then
    /usr/bin/pkill -f "$APP_PATTERN" > /dev/null 2>&1
    /bin/sleep 1
  fi
}

# run_limited <seconds> <command...>: runs the command and gives up on it after
# <seconds>, so a stuck app cannot hold the uninstall. Returns its exit status.
run_limited() {
  local limit="$1" pid ticks=0
  shift
  "$@" &
  pid=$!
  while /bin/kill -0 "$pid" 2> /dev/null; do
    if [ "$ticks" -ge $((limit * 4)) ]; then
      /bin/kill "$pid" > /dev/null 2>&1
      /usr/bin/pkill -f "$APP_BIN --unregister-login-item" > /dev/null 2>&1
      wait "$pid" 2> /dev/null
      return 1
    fi
    /bin/sleep 0.25
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# Asks the installed app to take itself out of Login Items, as the person at the
# console and in their login session, which is where macOS keeps the entry.
# The app says what it did. Succeeds when the entry is gone or never was there.
unregister_login_item() {
  local user uid
  [ -x "$APP_BIN" ] || return 1
  user="$(console_user)" || return 1
  uid="$(/usr/bin/id -u "$user" 2> /dev/null)"
  [ -n "$uid" ] || return 1
  run_limited 20 /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" "$APP_BIN" --unregister-login-item
}

remove_login_item() {
  if unregister_login_item; then
    return 0
  fi
  echo "Could not take Duette out of Login Items by itself."
  echo "If Duette is still listed, open System Settings > General > Login Items & Extensions and remove it there."
}

remove_path() {
  if [ -e "$1" ]; then
    /bin/rm -rf "$1" && echo "Removed $1"
  else
    echo "Not installed: $1"
  fi
}

forget_receipts() {
  local id found=0
  for id in $(/usr/sbin/pkgutil --pkgs 2> /dev/null | /usr/bin/grep '^me\.roboroads\.duette'); do
    /usr/sbin/pkgutil --forget "$id" > /dev/null 2>&1 && echo "Forgot installer receipt $id"
    found=1
  done
  [ "$found" -eq 1 ] || echo "No installer receipts found."
}

main() {
  if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "Administrator rights are needed. Asking for your password..."
    exec /usr/bin/sudo /bin/bash "$0" "$@"
  fi

  quit_app
  # While the app still exists: only the app can remove its own login item.
  remove_login_item
  remove_path "$APP"
  remove_path "$DRIVER"
  remove_path "$SUPPORT"
  forget_receipts

  echo "Restarting the audio system."
  /usr/bin/killall coreaudiod > /dev/null 2>&1
  echo "Duette is removed."
}

# Everything above is parsed before this runs, so deleting this very script
# in the middle of main is safe.
main "$@"
exit 0
