#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/Models"
MODEL_PATH="$MODEL_DIR/audio-model-fp16.mlpackage"
LABELS_PATH="$MODEL_DIR/labels/en_us.txt"
SOURCE_REPO="${BIRDNET_COREML_REPO:-/tmp/BirdNET-CoreML}"

if [[ ! -d "$SOURCE_REPO/coreml_export/output/audio-model-fp16.mlpackage" ]]; then
  echo "BirdNET-CoreML model not found at $SOURCE_REPO" >&2
  echo "Clone it first:" >&2
  echo "  git clone --depth 1 https://github.com/gioneill/BirdNET-CoreML.git $SOURCE_REPO" >&2
  exit 1
fi

mkdir -p "$MODEL_DIR/labels"
rm -rf "$MODEL_PATH"
cp -R "$SOURCE_REPO/coreml_export/output/audio-model-fp16.mlpackage" "$MODEL_PATH"
cp "$SOURCE_REPO/coreml_export/input/labels/en_us.txt" "$LABELS_PATH"

echo "Model ready: $MODEL_PATH"
echo "Labels ready: $LABELS_PATH"
