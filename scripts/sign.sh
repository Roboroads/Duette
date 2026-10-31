#!/usr/bin/env bash
# Code signing for the release build. macOS only.
#
#   scripts/sign.sh import-certs     Import the Developer ID certificates into a
#                                    temporary keychain (CI). No-op without them.
#   scripts/sign.sh bundles          Sign build/out/Duette.driver, Duette.app and
#                                    duettectl. Developer ID with the hardened
#                                    runtime and a secure timestamp when a
#                                    certificate is available, ad-hoc otherwise.
#   scripts/sign.sh identity <kind>  Print the SHA-1 of the "app" or "installer"
#                                    identity, or nothing if there is none.
#   scripts/sign.sh keychain         Print the temporary keychain path, if it exists.
#   scripts/sign.sh cleanup          Delete the temporary keychain.
#
# Inputs (all optional; without them everything falls back to ad-hoc signing):
#   MACOS_CERT_APP_P12_BASE64        base64 of the Developer ID Application .p12
#   MACOS_CERT_INSTALLER_P12_BASE64  base64 of the Developer ID Installer .p12
#   MACOS_CERT_PASSWORD              password of both .p12 files
#   APPLE_TEAM_ID                    if set, only identities of this team are used
#   DUETTE_APP_IDENTITY              use this codesign identity instead of searching
#   DUETTE_INSTALLER_IDENTITY        use this productbuild identity instead of searching
#   DUETTE_APP_ENTITLEMENTS          entitlements file for the app
#                                    (default app/Duette/Duette.entitlements)
#   DUETTE_OUT_DIR                   where the products are (default build/out)
#   DUETTE_KEYCHAIN                  path of the temporary keychain
#
# Runs on the bash 3.2 that ships with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${DUETTE_OUT_DIR:-build/out}"
KEYCHAIN_FILE="${DUETTE_KEYCHAIN:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/duette-signing.keychain-db}"
APP_ENTITLEMENTS="${DUETTE_APP_ENTITLEMENTS:-app/Duette/Duette.entitlements}"

die() { echo "sign.sh: $*" >&2; exit 1; }

# find_identity <name prefix>: print the SHA-1 of the first matching identity.
# Looks in the temporary keychain when it exists, in the default search list
# otherwise (a developer's own Mac). Valid identities win over invalid ones.
find_identity() {
  local kind="$1" valid_flag listing hash
  for valid_flag in "-v" ""; do
    if [ -f "$KEYCHAIN_FILE" ]; then
      # shellcheck disable=SC2086
      listing="$(security find-identity $valid_flag "$KEYCHAIN_FILE" 2>/dev/null || true)"
    else
      # shellcheck disable=SC2086
      listing="$(security find-identity $valid_flag 2>/dev/null || true)"
    fi
    hash="$(printf '%s\n' "$listing" | grep -F "\"$kind: " | {
      if [ -n "${APPLE_TEAM_ID:-}" ]; then grep -F "(${APPLE_TEAM_ID})" || true; else cat; fi
    } | awk 'NR == 1 { print $2 }')" || true
    if [ -n "$hash" ]; then
      printf '%s\n' "$hash"
      return 0
    fi
  done
  return 0
}

app_identity() {
  if [ -n "${DUETTE_APP_IDENTITY:-}" ]; then printf '%s\n' "$DUETTE_APP_IDENTITY"; else find_identity "Developer ID Application"; fi
}

installer_identity() {
  if [ -n "${DUETTE_INSTALLER_IDENTITY:-}" ]; then printf '%s\n' "$DUETTE_INSTALLER_IDENTITY"; else find_identity "Developer ID Installer"; fi
}

b64_to_file() { # <base64 text> <file>
  printf '%s' "$1" | base64 --decode > "$2"
}

cmd_import_certs() {
  if [ -z "${MACOS_CERT_APP_P12_BASE64:-}" ] && [ -z "${MACOS_CERT_INSTALLER_P12_BASE64:-}" ]; then
    echo "No signing certificates provided. Bundles will be ad-hoc signed and the pkg will be unsigned."
    return 0
  fi
  [ -n "${MACOS_CERT_PASSWORD:-}" ] || die "MACOS_CERT_PASSWORD is required together with the certificates"

  local work keychain_password
  work="$(mktemp -d)"
  # Expanded now on purpose: the trap must still know the path when this function is gone.
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  keychain_password="$(uuidgen)"

  rm -f "$KEYCHAIN_FILE"
  security create-keychain -p "$keychain_password" "$KEYCHAIN_FILE"
  # No auto-lock for six hours, so a long notarization wait cannot lock it.
  security set-keychain-settings -lut 21600 "$KEYCHAIN_FILE"
  security unlock-keychain -p "$keychain_password" "$KEYCHAIN_FILE"

  if [ -n "${MACOS_CERT_APP_P12_BASE64:-}" ]; then
    b64_to_file "$MACOS_CERT_APP_P12_BASE64" "$work/app.p12"
    security import "$work/app.p12" -f pkcs12 -k "$KEYCHAIN_FILE" -P "$MACOS_CERT_PASSWORD" \
      -T /usr/bin/codesign -T /usr/bin/security
  fi
  if [ -n "${MACOS_CERT_INSTALLER_P12_BASE64:-}" ]; then
    b64_to_file "$MACOS_CERT_INSTALLER_P12_BASE64" "$work/installer.p12"
    security import "$work/installer.p12" -f pkcs12 -k "$KEYCHAIN_FILE" -P "$MACOS_CERT_PASSWORD" \
      -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/security
  fi

  # Lets codesign and productbuild use the private keys without a prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
    "$KEYCHAIN_FILE" > /dev/null

  # Put the keychain first in the user's search list, keeping the others.
  local existing=()
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [ -n "$line" ] && existing+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$KEYCHAIN_FILE" ${existing[@]+"${existing[@]}"}

  echo "Identities in the temporary keychain:"
  security find-identity "$KEYCHAIN_FILE" | grep -E 'Developer ID|valid identities' || true

  if [ -n "${MACOS_CERT_APP_P12_BASE64:-}" ] && [ -z "$(app_identity)" ]; then
    die "no 'Developer ID Application' identity found after the import. Check the Application .p12 and APPLE_TEAM_ID."
  fi
  if [ -n "${MACOS_CERT_INSTALLER_P12_BASE64:-}" ] && [ -z "$(installer_identity)" ]; then
    die "no 'Developer ID Installer' identity found after the import. Check the Installer .p12 and APPLE_TEAM_ID."
  fi
}

# sign_item <path> [entitlements file] [identifier]
sign_item() {
  local item="$1" entitlements="${2:-}" identifier="${3:-}"
  local args=(--force)
  if [ -n "$APP_IDENTITY" ]; then
    args+=(--options runtime --timestamp --sign "$APP_IDENTITY")
    [ -f "$KEYCHAIN_FILE" ] && args+=(--keychain "$KEYCHAIN_FILE")
  else
    args+=(--sign -)
  fi
  [ -n "$entitlements" ] && args+=(--entitlements "$entitlements")
  [ -n "$identifier" ] && args+=(--identifier "$identifier")
  codesign "${args[@]}" "$item"
}

# sign_bundle <bundle> [entitlements file]: nested code first, then the bundle.
sign_bundle() {
  local bundle="$1" entitlements="${2:-}" nested
  # Reverse path order puts a nested item before the folder that contains it.
  while IFS= read -r -d '' nested; do
    sign_item "$nested"
  done < <(find "$bundle/Contents" \
    \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' -o -name '*.bundle' \) \
    -print0 2> /dev/null | sort -z -r)
  sign_item "$bundle" "$entitlements"
}

# verify_item <path>: strict signature check, plus runtime and timestamp for Developer ID.
verify_item() {
  local item="$1" details
  codesign --verify --deep --strict --verbose=2 "$item"
  details="$(codesign -dvv "$item" 2>&1)"
  if [ -n "$APP_IDENTITY" ]; then
    grep -E '^(Identifier|Authority=Developer ID Application|TeamIdentifier|Timestamp|CodeDirectory)' <<< "$details" || true
    grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<< "$details" || die "$item has no hardened runtime"
    grep -q '^Authority=Developer ID Application' <<< "$details" || die "$item is not signed with a Developer ID Application certificate"
    grep -q '^Timestamp=' <<< "$details" || die "$item has no secure timestamp"
  else
    grep -E '^(Identifier|Signature)' <<< "$details" || true
  fi
}

cmd_bundles() {
  APP_IDENTITY="$(app_identity)"
  if [ -n "$APP_IDENTITY" ]; then
    echo "Signing with Developer ID Application identity $APP_IDENTITY (hardened runtime, secure timestamp)."
  else
    echo "No Developer ID Application identity: signing ad-hoc. The result cannot be notarized."
  fi

  local driver="$OUT_DIR/Duette.driver" app="$OUT_DIR/Duette.app" cli="$OUT_DIR/duettectl"
  [ -d "$driver" ] || die "$driver not found. Run scripts/ci/build-driver.sh first."
  [ -d "$app" ] || die "$app not found. Run scripts/ci/build-app.sh first."

  local entitlements=""
  if [ -f "$APP_ENTITLEMENTS" ]; then
    entitlements="$APP_ENTITLEMENTS"
  else
    # Fall back to what the Xcode build already embedded in the app.
    local extracted
    extracted="$(mktemp)"
    codesign -d --entitlements :- "$app" > "$extracted" 2> /dev/null || true
    if plutil -lint "$extracted" > /dev/null 2>&1; then
      entitlements="$extracted"
      echo "Using the entitlements already embedded in $app."
    else
      echo "No entitlements file at $APP_ENTITLEMENTS and none embedded: signing the app without entitlements."
    fi
  fi

  sign_bundle "$driver"
  sign_bundle "$app" "$entitlements"
  if [ -f "$cli" ]; then
    sign_item "$cli" "" "me.roboroads.duette.duettectl"
  fi

  verify_item "$driver"
  verify_item "$app"
  if [ -f "$cli" ]; then verify_item "$cli"; fi
  if [ -n "$APP_IDENTITY" ] && [ -n "$entitlements" ]; then
    echo "Entitlements on the app:"
    codesign -d --entitlements :- "$app" 2> /dev/null || true
  fi
}

cmd_cleanup() {
  if [ -f "$KEYCHAIN_FILE" ]; then
    security delete-keychain "$KEYCHAIN_FILE" || true
    echo "Deleted $KEYCHAIN_FILE."
  fi
}

APP_IDENTITY=""

case "${1:-}" in
  import-certs) cmd_import_certs ;;
  bundles) cmd_bundles ;;
  identity)
    case "${2:-}" in
      app) app_identity ;;
      installer) installer_identity ;;
      *) die "usage: sign.sh identity app|installer" ;;
    esac
    ;;
  keychain) if [ -f "$KEYCHAIN_FILE" ]; then printf '%s\n' "$KEYCHAIN_FILE"; fi ;;
  cleanup) cmd_cleanup ;;
  *) die "usage: sign.sh import-certs | bundles | identity app|installer | keychain | cleanup" ;;
esac
