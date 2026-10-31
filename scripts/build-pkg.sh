#!/usr/bin/env bash
# Builds the installer package from the products in build/out. macOS only.
#
#   scripts/build-pkg.sh
#
# Reads:
#   build/out/Duette.app, build/out/Duette.driver   (required, already signed)
#   build/out/duettectl                              (optional, goes to the support folder)
#   version.txt, packaging/**
# Writes build/release/:
#   Duette-<version>[-<suffix>].pkg   signed with the Developer ID Installer
#                                     certificate when there is one, unsigned otherwise
#   uninstall.sh                      the same file the pkg installs
#   TESTING.md                        only if docs/TESTING.md exists
#
# Inputs (optional):
#   DUETTE_PKG_SUFFIX    for test builds: Duette-0.1.0-test-abc1234.pkg
#   DUETTE_OUT_DIR       default build/out
#   DUETTE_RELEASE_DIR   default build/release
#   DUETTE_WORK_DIR      default build/pkg-work
#   the signing inputs of scripts/sign.sh
#
# With GITHUB_OUTPUT set, appends pkg_path=<path> and signed=true|false to it.
#
# Runs on the bash 3.2 that ships with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${DUETTE_OUT_DIR:-build/out}"
RELEASE_DIR="${DUETTE_RELEASE_DIR:-build/release}"
WORK_DIR="${DUETTE_WORK_DIR:-build/pkg-work}"
SUFFIX="${DUETTE_PKG_SUFFIX:-}"

PKG_IDENTIFIER="me.roboroads.duette.pkg"
APP_ID="me.roboroads.duette"
DRIVER_ID="me.roboroads.duette.driver"

die() { echo "build-pkg.sh: $*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < version.txt)"
[ -n "$VERSION" ] || die "version.txt is empty"
case "$SUFFIX" in
  *[!A-Za-z0-9._-]*) die "DUETTE_PKG_SUFFIX may only contain letters, digits, dots, dashes and underscores" ;;
esac

APP="$OUT_DIR/Duette.app"
DRIVER="$OUT_DIR/Duette.driver"
CLI="$OUT_DIR/duettectl"

plist_get() { # <plist> <key>
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2> /dev/null || true
}

# check_bundle <bundle> <expected bundle id>
check_bundle() {
  local bundle="$1" info id version
  info="$bundle/Contents/Info.plist"
  [ -d "$bundle" ] || die "$bundle not found. Run the build scripts in scripts/ci/ first."
  [ -f "$info" ] || die "$bundle has no Contents/Info.plist"
  id="$(plist_get "$info" CFBundleIdentifier)"
  [ "$id" = "$2" ] || die "$bundle: CFBundleIdentifier is '$id', expected '$2'"
  version="$(plist_get "$info" CFBundleShortVersionString)"
  [ "$version" = "$VERSION" ] || die "$bundle: CFBundleShortVersionString is '$version' but version.txt says '$VERSION'"
}

check_bundle "$APP" "$APP_ID"
check_bundle "$DRIVER" "$DRIVER_ID"

INSTALLER_IDENTITY="$(bash scripts/sign.sh identity installer)"
KEYCHAIN="$(bash scripts/sign.sh keychain)"

if [ -n "$INSTALLER_IDENTITY" ]; then
  # A pkg signed with a real certificate is meant for notarization, which rejects
  # anything inside that is not Developer ID signed.
  for bundle in "$APP" "$DRIVER"; do
    details="$(codesign -dvv "$bundle" 2>&1)"
    grep -q '^Authority=Developer ID Application' <<< "$details" \
      || die "$bundle is not signed with a Developer ID Application certificate. Run scripts/sign.sh bundles first."
  done
  echo "Signing the pkg with Developer ID Installer identity $INSTALLER_IDENTITY."
else
  echo "No Developer ID Installer identity: the pkg will be unsigned."
fi

# 1. Stage the payload.
rm -rf "$WORK_DIR" "$RELEASE_DIR"
ROOT="$WORK_DIR/root"
SUPPORT="$ROOT/Library/Application Support/Duette"
mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL" "$SUPPORT" "$WORK_DIR/packages" "$RELEASE_DIR"
ditto "$APP" "$ROOT/Applications/Duette.app"
ditto "$DRIVER" "$ROOT/Library/Audio/Plug-Ins/HAL/Duette.driver"
install -m 755 packaging/uninstall.sh "$SUPPORT/uninstall.sh"
install -m 755 scripts/duette-diagnose.sh "$SUPPORT/duette-diagnose.sh"
if [ -f "$CLI" ]; then install -m 755 "$CLI" "$SUPPORT/duettectl"; fi

mkdir -p "$WORK_DIR/scripts"
for script in packaging/scripts/*; do
  install -m 755 "$script" "$WORK_DIR/scripts/$(basename "$script")"
done

# 2. Component properties. Let pkgbuild list the bundles it finds, then turn off the two
# defaults that hurt us: relocation (the installer would "update" a Duette.app it finds
# elsewhere, such as a build folder) and the version check (the build number is a CI run
# counter, so a newer pkg can carry a lower number than an older one).
COMPONENTS="$WORK_DIR/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS" > /dev/null
count=0
while /usr/libexec/PlistBuddy -c "Print :$count:RootRelativeBundlePath" "$COMPONENTS" > /dev/null 2>&1; do
  for key in BundleIsRelocatable BundleIsVersionChecked; do
    /usr/libexec/PlistBuddy -c "Set :$count:$key false" "$COMPONENTS" 2> /dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$count:$key bool false" "$COMPONENTS"
  done
  count=$((count + 1))
done
[ "$count" -ge 2 ] || die "pkgbuild found $count bundles in the payload, expected the app and the driver"
echo "Component properties:"
plutil -p "$COMPONENTS"

# 3. Component package (carries the payload and the install scripts).
pkgbuild \
  --root "$ROOT" \
  --component-plist "$COMPONENTS" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  --scripts "$WORK_DIR/scripts" \
  --ownership recommended \
  "$WORK_DIR/packages/Duette-component.pkg"

# 4. Product archive (the installer window, the OS and architecture checks), signed if possible.
sed -e "s|@VERSION@|$VERSION|g" -e "s|@COMPONENT@|Duette-component.pkg|g" \
  packaging/distribution.xml > "$WORK_DIR/distribution.xml"

PKG_NAME="Duette-$VERSION${SUFFIX:+-$SUFFIX}.pkg"
PKG="$RELEASE_DIR/$PKG_NAME"
build_args=(--distribution "$WORK_DIR/distribution.xml" --resources packaging/resources --package-path "$WORK_DIR/packages")
if [ -n "$INSTALLER_IDENTITY" ]; then
  build_args+=(--sign "$INSTALLER_IDENTITY" --timestamp)
  if [ -n "$KEYCHAIN" ]; then build_args+=(--keychain "$KEYCHAIN"); fi
fi
productbuild "${build_args[@]}" "$PKG"

echo "Signature of $PKG:"
signature="$(pkgutil --check-signature "$PKG" 2>&1 || true)"
echo "$signature"
signed=false
if [ -n "$INSTALLER_IDENTITY" ]; then
  grep -q 'Developer ID Installer' <<< "$signature" || die "the pkg is not signed with the Developer ID Installer certificate"
  grep -qi 'trusted timestamp' <<< "$signature" || die "the pkg signature has no trusted timestamp"
  signed=true
fi

# 5. The other release files.
install -m 755 packaging/uninstall.sh "$RELEASE_DIR/uninstall.sh"
if [ -f docs/TESTING.md ]; then cp docs/TESTING.md "$RELEASE_DIR/TESTING.md"; fi

echo "Built $PKG"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "pkg_path=$PKG"
    echo "signed=$signed"
  } >> "$GITHUB_OUTPUT"
fi
