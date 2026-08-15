#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="EdgeBeat Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "==> '$CERT_NAME' already exists"
  exit 0
fi

echo "==> creating a local code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TEMP_DIR/edgebeat.key" \
  -out "$TEMP_DIR/edgebeat.crt" \
  -days 3650 \
  -subj "/CN=$CERT_NAME/O=EdgeBeat/OU=Development" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  >/dev/null 2>&1

openssl pkcs12 -export \
  -out "$TEMP_DIR/edgebeat.p12" \
  -inkey "$TEMP_DIR/edgebeat.key" \
  -in "$TEMP_DIR/edgebeat.crt" \
  -passout pass: \
  -name "$CERT_NAME" \
  >/dev/null 2>&1

security import "$TEMP_DIR/edgebeat.p12" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

echo "==> installed '$CERT_NAME'"
echo "    Re-run scripts/build.sh; TCC grants will now survive rebuilds."
