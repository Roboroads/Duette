#!/bin/bash
# Removes Duette from this Mac.
#
#   sudo "/Library/Application Support/Duette/uninstall.sh"
#
# Removes the app, the audio driver and the support folder, forgets the
# installer receipts and restarts the audio system. Your Duette settings in
# ~/Library/Preferences are left alone, so a later reinstall keeps them.
#
# This is the pkg's own copy. scripts/uninstall.sh (the dev-machine script)
# does much the same for a locally built install; the two can be merged later.
#
# Runs on the bash 3.2 that ships with macOS.

APP="/Applications/Duette.app"
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

remove_path() {
  if [ -e "$1" ]; then
    /bin/rm -rf "$1" && echo "Removed $1"
  else
    echo "Not installed: $1"
  fi
}

forget_receipts() {
  local id found=0
  for id in $(/usr/sbin/pkgutil --pkgs='me\.roboroads\.duette' 2> /dev/null); do
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
