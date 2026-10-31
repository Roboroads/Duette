#!/usr/bin/env bash
# Build and test the Duette menu bar app (app/). macOS only.
#
# Steps:
#   1. generate app/Duette.xcodeproj from app/project.yml with XcodeGen (git-ignored);
#   2. Release build for arm64 into build/app/derived, copied to build/out/Duette.app;
#   3. check the product: Info.plist keys and usage strings, architecture, entitlements;
#   4. unit tests (Debug) in build/test-out/app, which packaging never reads.
#
# The version comes from version.txt (CFBundleShortVersionString) and GITHUB_RUN_NUMBER, default
# 0 (CFBundleVersion). The app is ad-hoc signed here; scripts/sign.sh re-signs it for releases.
#
# Environment:
#   DUETTE_APP_BUILD_DIR  where the Release build tree goes (default: <repo>/build/app)
#   DUETTE_APP_TEST_DIR   where the test build tree goes (default: <repo>/build/test-out/app)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
build_root=${DUETTE_APP_BUILD_DIR:-$repo_root/build/app}
test_root=${DUETTE_APP_TEST_DIR:-$repo_root/build/test-out/app}
out_dir=$repo_root/build/out
app=$out_dir/Duette.app

if [ "$(uname -s)" != Darwin ]; then
  echo "build-app.sh: the app needs macOS and its SDK" >&2
  exit 2
fi

version=$(tr -d '[:space:]' < version.txt)
build_number=${GITHUB_RUN_NUMBER:-0}
destination='platform=macOS,arch=arm64'

xcodebuild -version

if ! command -v xcodegen > /dev/null 2>&1; then
  echo "==> Installing XcodeGen"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew install xcodegen
fi

echo "==> App: generate the Xcode project"
xcodegen generate --spec app/project.yml

echo "==> App: Release build (version $version, build $build_number)"
rm -rf "$build_root"
mkdir -p "$build_root" "$out_dir"
xcodebuild build \
  -project app/Duette.xcodeproj \
  -scheme Duette \
  -configuration Release \
  -destination "$destination" \
  -derivedDataPath "$build_root/derived" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number"

rm -rf "$app"
ditto "$build_root/derived/Build/Products/Release/Duette.app" "$app"

echo "==> App: check the product"
die() { echo "build-app.sh: $*" >&2; exit 1; }
plist=$app/Contents/Info.plist
plutil -lint "$plist"

plist_value() { # <key>: the value as plain text
  plutil -extract "$1" raw -o - "$plist" 2> /dev/null || true
}
expect() { # <key> <expected value>
  local value
  value=$(plist_value "$1")
  [ "$value" = "$2" ] || die "Info.plist $1 is '$value', expected '$2'"
}
expect_text() { # <key>: must be a non-empty string
  [ -n "$(plist_value "$1")" ] || die "Info.plist $1 is missing or empty"
}
expect CFBundleIdentifier me.roboroads.duette
expect CFBundleShortVersionString "$version"
expect CFBundleVersion "$build_number"
expect LSMinimumSystemVersion 14.2
expect LSUIElement true
expect_text NSMicrophoneUsageDescription
expect_text NSAudioCaptureUsageDescription

archs=$(lipo -archs "$app/Contents/MacOS/Duette")
[ "$archs" = arm64 ] || die "the app binary is '$archs', expected arm64 only"

codesign --verify --deep --strict --verbose=2 "$app"
entitlements=$(mktemp)
codesign -d --entitlements :- "$app" > "$entitlements" 2> /dev/null || true
echo "Entitlements on the app:"
cat "$entitlements"
plutil -lint "$entitlements" > /dev/null || die "the app has no readable entitlements"
audio_input=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.device.audio-input" "$entitlements" 2> /dev/null || true)
[ "$audio_input" = true ] || die "the app lacks the com.apple.security.device.audio-input entitlement"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$entitlements" > /dev/null 2>&1; then
  die "the Release app has com.apple.security.get-task-allow, which notarization rejects"
fi
rm -f "$entitlements"

echo "==> App: unit tests"
rm -rf "$test_root"
mkdir -p "$test_root"
xcodebuild test \
  -project app/Duette.xcodeproj \
  -scheme Duette \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$test_root/derived" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" 2>&1 | tee "$test_root/test.log"

echo "==> App: test summary"
grep -E "Executed [0-9]+ tests?, with" "$test_root/test.log" | tail -n 1

echo "==> App passed"
