#!/usr/bin/env bash
# Launch note-taker-bar.app via `open` so TCC attributes permissions correctly
# to the bundle (not to the terminal). Required for Accessibility + Microphone.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/note-taker-bar.app"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run ./scripts/build.sh first" >&2
    exit 1
fi

open "$APP"
