#!/usr/bin/env bash
# Download a whisper.cpp GGML model into models/.
# Usage: ./scripts/download_model.sh [base|small|medium|large-v3]
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

# Minimum expected sizes (bytes) — real models are much larger; these guard
# against silent HTML error pages being saved as model files.
declare -A MIN_SIZE
MIN_SIZE["tiny"]=70000000                  # ~75 MB
MIN_SIZE["base"]=140000000                 # ~142 MB
MIN_SIZE["small"]=460000000                # ~466 MB
MIN_SIZE["medium"]=1400000000              # ~1.5 GB
MIN_SIZE["medium-q5_0"]=510000000          # ~539 MB
MIN_SIZE["medium-q8_0"]=830000000          # ~884 MB
MIN_SIZE["large-v3"]=3000000000            # ~3.1 GB
MIN_SIZE["large-v3-q5_0"]=1000000000       # ~1.1 GB
MIN_SIZE["large-v3-turbo"]=750000000       # ~809 MB
MIN_SIZE["large-v3-turbo-q5_0"]=500000000  # ~547 MB
MIN_SIZE["large-v3-turbo-q8_0"]=820000000  # ~874 MB
MIN_SIZE["large-v2"]=3000000000
MIN_SIZE["large"]=3000000000

MIN=${MIN_SIZE[$MODEL]:-10000000}  # default 10 MB for unknown models
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
