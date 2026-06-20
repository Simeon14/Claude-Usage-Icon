#!/bin/bash
# Create a stable, self-signed code-signing identity for this app.
#
# Why: macOS only durably honors "Always Allow" for Keychain access when the
# requesting app has a STABLE code identity. An ad-hoc signature has none, so the
# app gets re-prompted for the Claude token every time the token refreshes. Signing
# with a real (even self-signed) certificate fixes that.
#
# Idempotent: does nothing if the identity already exists. Run once, then build.sh
# will sign with it automatically.
set -euo pipefail

CN="Claude Usage Icon Local Signing"
PW="cuilocal"   # transient password for the PKCS#12 hand-off only

if security find-certificate -c "$CN" >/dev/null 2>&1; then
  echo "Signing identity already present: $CN"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=$CN" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" 2>/dev/null

# -legacy: Apple's `security` can't read OpenSSL 3's default PKCS#12 MAC algorithm.
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$PW" -name "$CN" 2>/dev/null

echo "==> Importing into the login keychain (codesign-accessible)"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign

echo "==> Done. Identity created: $CN"
echo "    On the first build/sign you'll get ONE Keychain prompt for 'codesign'"
echo "    to use this key — click Always Allow (it's this new key, not your token)."
