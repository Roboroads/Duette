#!/usr/bin/env bash
# Creates minimal stand-in bundles in build/out (or the folder given as $1), so the
# packaging pipeline can be tested before, or without, the real driver and app.
# macOS only: it compiles empty executables with clang.
#
#   packaging/tests/make-stub-bundles.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT_DIR="${1:-build/out}"
VERSION="$(tr -d '[:space:]' < version.txt)"
BUILD="${GITHUB_RUN_NUMBER:-0}"

rm -rf "$OUT_DIR/Duette.app" "$OUT_DIR/Duette.driver" "$OUT_DIR/duettectl"
mkdir -p "$OUT_DIR"

# write_info <path> <bundle id> <package type> <extra plist lines>
write_info() {
  cat > "$1" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>Duette</string>
  <key>CFBundleExecutable</key><string>Duette</string>
  <key>CFBundlePackageType</key><string>$3</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
$4
</dict>
</plist>
EOF
}

compile() { # <output> [extra clang flags]
  local output="$1"
  shift
  printf 'int main(void) { return 0; }\n' | clang -x c -arch arm64 "$@" -o "$output" -
}

# App, with a nested dylib so the inside-out signing path runs. Like the real app it understands
# --unregister-login-item (what the uninstaller runs): it says so, and leaves a line in
# /tmp/duette-stub-unregister for packaging/tests/install-test.sh to find.
app="$OUT_DIR/Duette.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
write_info "$app/Contents/Info.plist" "me.roboroads.duette" "APPL" "  <key>LSUIElement</key><true/>"
cat << 'EOF' | clang -x c -arch arm64 -o "$app/Contents/MacOS/Duette" -
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--unregister-login-item") == 0) {
    FILE *marker = fopen("/tmp/duette-stub-unregister", "a");
    if (marker != NULL) {
      fputs("--unregister-login-item\n", marker);
      fclose(marker);
    }
    puts("Removed Duette from Login Items.");
  }
  return 0;
}
EOF
printf 'void stub(void) {}\n' | clang -x c -arch arm64 -dynamiclib -o "$app/Contents/Frameworks/libstub.dylib" -

# Driver, a loadable bundle like a HAL plug-in.
driver="$OUT_DIR/Duette.driver"
mkdir -p "$driver/Contents/MacOS"
write_info "$driver/Contents/Info.plist" "me.roboroads.duette.driver" "BNDL" ""
compile "$driver/Contents/MacOS/Duette" -bundle

# Command line tool.
compile "$OUT_DIR/duettectl"
chmod +x "$OUT_DIR/duettectl"

plutil -lint "$app/Contents/Info.plist" "$driver/Contents/Info.plist"
echo "Stub bundles written to $OUT_DIR"
