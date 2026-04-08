#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-large-v3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$ROOT/models"
SCRIPT="$ROOT/whisper.cpp/models/download-ggml-model.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "error: whisper.cpp submodule not initialised — run: git submodule update --init" >&2
    exit 1
fi

mkdir -p "$MODELS_DIR"

# whisper.cpp's script downloads into its own models/ dir — redirect output here
TARGET="$MODELS_DIR/ggml-${MODEL}.bin"
if [[ -f "$TARGET" ]]; then
    echo "Model $MODEL already exists at $TARGET. Skipping download."
    exit 0
fi

# Download into whisper.cpp/models/ then move to our models/
cd "$ROOT/whisper.cpp/models"
bash "$SCRIPT" "$MODEL"
mv "$ROOT/whisper.cpp/models/ggml-${MODEL}.bin" "$TARGET"
echo "Model saved to $TARGET"
