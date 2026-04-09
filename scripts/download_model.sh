#!/usr/bin/env bash
# Download a whisper.cpp GGML model into models/.
# Usage: ./scripts/download_model.sh [base|small|medium|large-v3|large-v3-turbo|...]
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

TARGET="$MODELS_DIR/ggml-${MODEL}.bin"
if [[ -f "$TARGET" ]]; then
    echo "Model $MODEL already exists at $TARGET. Skipping download."
    exit 0
fi

# Download into whisper.cpp/models/ then move to our models/
cd "$ROOT/whisper.cpp/models"
bash "$SCRIPT" "$MODEL"

DOWNLOADED="$ROOT/whisper.cpp/models/ggml-${MODEL}.bin"

# Minimum expected sizes in bytes — guards against curl saving an HTML error
# page instead of the model (bash 3.2 compatible, no associative arrays).
min_size_for_model() {
    case "$1" in
        tiny*)                  echo 70000000   ;;  # ~75 MB
        base*)                  echo 140000000  ;;  # ~142 MB
        small*)                 echo 460000000  ;;  # ~466 MB
        medium-q5_0)            echo 510000000  ;;  # ~539 MB
        medium-q8_0)            echo 830000000  ;;  # ~884 MB
        medium*)                echo 1400000000 ;;  # ~1.5 GB
        large-v3-turbo-q5_0)    echo 500000000  ;;  # ~547 MB
        large-v3-turbo-q8_0)    echo 820000000  ;;  # ~874 MB
        large-v3-turbo*)        echo 750000000  ;;  # ~809 MB
        large*)                 echo 3000000000 ;;  # ~3.1 GB
        *)                      echo 10000000   ;;  # 10 MB default
    esac
}

MIN=$(min_size_for_model "$MODEL")
ACTUAL=$(wc -c < "$DOWNLOADED" | tr -d ' ')

if (( ACTUAL < MIN )); then
    echo "" >&2
    echo "error: downloaded file is only ${ACTUAL} bytes (expected >= ${MIN})." >&2
    echo "       The server likely returned an error page instead of the model." >&2
    echo "       Removing the corrupt file. Try again in a few minutes." >&2
    rm -f "$DOWNLOADED"
    exit 1
fi

mv "$DOWNLOADED" "$TARGET"
echo "Model saved to $TARGET ($(du -h "$TARGET" | cut -f1))"
