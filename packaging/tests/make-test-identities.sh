#!/usr/bin/env bash
# Makes two self-signed identities named like the Developer ID ones, so the certificate
# import and code signing path of scripts/sign.sh can be exercised without Apple's
# certificates. They are not trusted by anything, cannot be notarized, and productbuild
# does not accept the "installer" one for signing a pkg (it checks Apple's certificate
# profile), so only the import, lookup and codesign steps are covered.
#
#   packaging/tests/make-test-identities.sh <dir>
#
# Writes into <dir>: application.p12.b64, installer.p12.b64, combined.p12.b64,
# installer-own-password.p12.b64 (base64 text), password and installer-password. The combined file holds both identities, built on one private
# key, like a .p12 that carries the Application and the Installer certificate.
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "usage: make-test-identities.sh <dir>" >&2; exit 2; }
mkdir -p "$dir"
cd "$dir"

password="$(uuidgen)"
printf '%s' "$password" > password

make_identity() { # <file name> <common name> [existing key file]
  local name="$1" cn="$2" key="${3:-}"
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
extendedKeyUsage = critical, codeSigning
EOF
  if [ -n "$key" ]; then
    openssl req -x509 -key "$key" -days 2 -config "$name.cnf" -out "$name.pem" 2> /dev/null
  else
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$name.cnf" \
      -keyout "$name.key" -out "$name.pem" 2> /dev/null
  fi
  # Only the certificate is needed when the key is shared with another identity.
  [ -z "$key" ] || return 0
  # OpenSSL 3 needs -legacy for macOS to read the file; LibreSSL does not know the flag.
  if ! openssl pkcs12 -export -legacy -inkey "$name.key" -in "$name.pem" \
    -passout pass:"$password" -out "$name.p12" 2> /dev/null; then
    openssl pkcs12 -export -inkey "$name.key" -in "$name.pem" \
      -passout pass:"$password" -out "$name.p12"
  fi
  base64 < "$name.p12" | tr -d '\n' > "$name.p12.b64"
}

make_identity application "Developer ID Application: Duette CI Probe (TEST123456)"
make_identity installer "Developer ID Installer: Duette CI Probe (TEST123456)"

# Both identities in one file: the Application key and certificate, plus an Installer
# certificate made from the same key.
make_identity combined-installer "Developer ID Installer: Duette CI Probe (TEST123456)" application.key
if ! openssl pkcs12 -export -legacy -inkey application.key -in application.pem -certfile combined-installer.pem \
  -passout pass:"$password" -out combined.p12 2> /dev/null; then
  openssl pkcs12 -export -inkey application.key -in application.pem -certfile combined-installer.pem \
    -passout pass:"$password" -out combined.p12
fi
base64 < combined.p12 | tr -d '\n' > combined.p12.b64

# The Installer identity again, in a file with its own password.
installer_password="$(uuidgen)"
printf '%s' "$installer_password" > installer-password
if ! openssl pkcs12 -export -legacy -inkey installer.key -in installer.pem \
  -passout pass:"$installer_password" -out installer-own-password.p12 2> /dev/null; then
  openssl pkcs12 -export -inkey installer.key -in installer.pem \
    -passout pass:"$installer_password" -out installer-own-password.p12
fi
base64 < installer-own-password.p12 | tr -d '\n' > installer-own-password.p12.b64

rm -f ./*.key ./*.pem ./*.cnf ./*.p12
echo "Wrote application.p12.b64, installer.p12.b64, combined.p12.b64, installer-own-password.p12.b64, password and installer-password to $dir"
