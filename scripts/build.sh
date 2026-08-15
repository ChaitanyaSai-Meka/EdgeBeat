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
if [ -f "$ROOT/Resources/mediaremote-adapter.pl" ]; then
  cp "$ROOT/Resources/mediaremote-adapter.pl" "$CONTENTS/Resources/mediaremote-adapter.pl"
fi
if [ -f "$ROOT/Resources/MediaRemoteAdapter.LICENSE" ]; then
  cp "$ROOT/Resources/MediaRemoteAdapter.LICENSE" "$CONTENTS/Resources/MediaRemoteAdapter.LICENSE"
fi
if [ -d "$ROOT/Resources/MediaRemoteAdapter.framework" ]; then
  cp -R "$ROOT/Resources/MediaRemoteAdapter.framework" "$CONTENTS/Resources/MediaRemoteAdapter.framework"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

SIGN_ID="${EDGEBEAT_SIGN_ID:--}"
echo "==> codesign with '$SIGN_ID'"
codesign --force --sign "$SIGN_ID" "$APP_DIR"

echo "==> built: $APP_DIR"
