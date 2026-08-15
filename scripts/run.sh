#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/build.sh"
pkill -x EdgeBeat 2>/dev/null || true
echo "==> launching EdgeBeat.app"
open "$ROOT/EdgeBeat.app"
