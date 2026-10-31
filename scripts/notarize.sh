#!/usr/bin/env bash
# Notarize and staple the installer package. macOS only.
#
#   scripts/notarize.sh build/release/Duette-0.1.0.pkg
#
# Inputs (App Store Connect API key; see docs/SIGNING.md):
#   ASC_KEY_ID          key ID
#   ASC_ISSUER_ID       issuer ID
#   ASC_KEY_P8_BASE64   base64 of the AuthKey_<id>.p8 file
#
# Without all three, or when the pkg is not signed with a Developer ID
# Installer certificate, nothing is submitted and the script exits 0 with
# "notarized=false". After a successful run: "notarized=true". With
# GITHUB_OUTPUT set, the same line is appended to it.
#
# The notarization log is saved next to the pkg as notarization-log.json.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "notarize.sh: $*" >&2; exit 1; }

set_result() { # true|false
  echo "notarized=$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "notarized=$1" >> "$GITHUB_OUTPUT"; fi
}

pkg="${1:-}"
[ -n "$pkg" ] || die "usage: notarize.sh <pkg>"
[ -f "$pkg" ] || die "$pkg not found"

if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_P8_BASE64:-}" ]; then
  echo "No App Store Connect API key provided: skipping notarization."
  set_result false
  exit 0
fi

signature="$(pkgutil --check-signature "$pkg" 2>&1 || true)"
if ! grep -q 'Developer ID Installer' <<< "$signature"; then
  echo "$pkg is not signed with a Developer ID Installer certificate: skipping notarization."
  echo "$signature"
  set_result false
  exit 0
fi

command -v jq > /dev/null 2>&1 || brew install jq

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
key_file="$work/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$key_file"
chmod 600 "$key_file"

auth=(--key "$key_file" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
log_file="$(dirname "$pkg")/notarization-log.json"

echo "Submitting $pkg to the Apple notary service..."
# notarytool exits 0 for a rejected submission too, so read the status from its JSON.
xcrun notarytool submit "$pkg" "${auth[@]}" --wait --timeout 60m --output-format json > "$work/submit.json"
cat "$work/submit.json"
submission_id="$(jq -r '.id // empty' "$work/submit.json")"
status="$(jq -r '.status // empty' "$work/submit.json")"
[ -n "$submission_id" ] || die "notarytool returned no submission id"

# Keep the log as evidence whether the submission passed or not.
xcrun notarytool log "$submission_id" "${auth[@]}" "$log_file" || echo "Could not fetch the notarization log."
if [ -f "$log_file" ]; then cat "$log_file"; fi

if [ "$status" != "Accepted" ]; then
  die "notarization finished with status '$status' (submission $submission_id). See the log above."
fi

xcrun stapler staple "$pkg"
xcrun stapler validate "$pkg"
# What Gatekeeper says about an installer: expect "accepted", "source=Notarized Developer ID".
spctl -a -t install -vv "$pkg"

set_result true
