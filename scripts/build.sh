#!/usr/bin/env bash
set -euo pipefail

APP_NAME="EdgeBeat"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> swift build (release)"
cd "$ROOT"

# Newer Command Line Tools can occasionally be installed alongside an SDK built
# by a slightly older compiler. Prefer the oldest installed macOS SDK unless the
# caller explicitly supplies one; Swift remains backward-compatible with it.
if [ -z "${EDGEBEAT_SDKROOT:-}" ]; then
  SDK_DIR="$(dirname "$(xcrun --sdk macosx --show-sdk-path)")"
  EDGEBEAT_SDKROOT="$(find "$SDK_DIR" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -V | head -n 1)"
fi
export SDKROOT="${EDGEBEAT_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
echo "==> SDK: $SDKROOT"
swift build -c release

echo "==> assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Signing identity: env override > self-signed cert (if present) > ad-hoc.
SIGN_ID="${EDGEBEAT_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "EdgeBeat Self-Signed"; then
    SIGN_ID="EdgeBeat Self-Signed"
  fi
fi

if [ -n "$SIGN_ID" ]; then
  echo "==> codesign with '$SIGN_ID' (TCC permission grants persist across rebuilds)"
  codesign --force --sign "$SIGN_ID" "$APP_DIR"
else
  echo "==> codesign ad-hoc (macOS may re-ask for permissions after each rebuild;"
  echo "    run scripts/make-signing-cert.sh once so grants stick)"
  codesign --force --sign - "$APP_DIR"
fi

echo "==> built: $APP_DIR"
