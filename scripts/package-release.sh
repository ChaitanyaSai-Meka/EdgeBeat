#!/usr/bin/env bash
set -euo pipefail

APP_NAME="EdgeBeat"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_PATH="${1:-$ROOT/$APP_NAME.zip}"

if [[ "$(basename "$ARCHIVE_PATH")" != "$APP_NAME.zip" ]]; then
  echo "error: the release archive must be named $APP_NAME.zip" >&2
  exit 2
fi

"$ROOT/scripts/build.sh"

echo "==> packaging $ARCHIVE_PATH"
rm -f "$ARCHIVE_PATH"
mkdir -p "$(dirname "$ARCHIVE_PATH")"
# ditto preserves the app bundle layout, resource forks, and Finder metadata.
ditto -c -k --sequesterRsrc --keepParent "$ROOT/$APP_NAME.app" "$ARCHIVE_PATH"

echo "==> packaged: $ARCHIVE_PATH"
