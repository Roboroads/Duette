#!/usr/bin/env bash
# Makes two self-signed identities named like the Developer ID ones, so the signing
# code path in scripts/sign.sh and scripts/build-pkg.sh can be exercised without
# Apple's certificates. They are not trusted by anything and cannot be notarized.
#
#   packaging/tests/make-test-identities.sh <dir>
#
# Writes into <dir>: application.p12.b64, installer.p12.b64 (base64 text) and password.
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "usage: make-test-identities.sh <dir>" >&2; exit 2; }
mkdir -p "$dir"
cd "$dir"

password="$(uuidgen)"
printf '%s' "$password" > password

make_identity() { # <file name> <common name> <extended key usage>
  local name="$1" cn="$2" eku="$3"
  cat > "$name.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $cn
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, $eku
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$name.cnf" \
    -keyout "$name.key" -out "$name.pem" 2> /dev/null
  # OpenSSL 3 needs -legacy for macOS to read the file; LibreSSL does not know the flag.
  if ! openssl pkcs12 -export -legacy -inkey "$name.key" -in "$name.pem" \
    -passout pass:"$password" -out "$name.p12" 2> /dev/null; then
    openssl pkcs12 -export -inkey "$name.key" -in "$name.pem" \
      -passout pass:"$password" -out "$name.p12"
  fi
  base64 < "$name.p12" | tr -d '\n' > "$name.p12.b64"
}

make_identity application "Developer ID Application: Duette CI Probe (TEST123456)" "codeSigning"
make_identity installer "Developer ID Installer: Duette CI Probe (TEST123456)" "codeSigning, 1.2.840.113635.100.4.13"
rm -f ./*.key ./*.pem ./*.cnf ./*.p12
echo "Wrote application.p12.b64, installer.p12.b64 and password to $dir"
