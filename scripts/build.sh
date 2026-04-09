#!/usr/bin/env bash
# Build note-taker-bar and reset the Accessibility TCC entry so macOS
# recognises the new ad-hoc signature after each rebuild.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

cmake -B "$REPO/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build "$REPO/build" --parallel

echo ""
echo "Resetting Accessibility TCC entry for note-taker-bar..."
tccutil reset Accessibility com.local.note-taker-bar
echo "Done. Run ./scripts/start.sh to launch."
