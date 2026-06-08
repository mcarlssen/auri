#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Auri/Resources/BirdNet"
SOURCE_REPO="${BIRDNET_COREML_REPO:-/tmp/BirdNET-CoreML}"
SOURCE_MODEL="$SOURCE_REPO/coreml_export/output/audio-model-fp16.mlpackage"
SOURCE_LABELS="$SOURCE_REPO/coreml_export/input/labels/en_us.txt"
FALLBACK_MODEL="$ROOT/Tools/CoreMLSpike/Models/audio-model-fp16.mlpackage"
FALLBACK_LABELS="$ROOT/Tools/CoreMLSpike/Models/labels/en_us.txt"

mkdir -p "$DEST/labels"

if [[ -d "$SOURCE_MODEL" ]]; then
  rm -rf "$DEST/audio-model-fp16.mlpackage"
  cp -R "$SOURCE_MODEL" "$DEST/"
  cp "$SOURCE_LABELS" "$DEST/labels/en_us.txt"
elif [[ -d "$FALLBACK_MODEL" ]]; then
  rm -rf "$DEST/audio-model-fp16.mlpackage"
  cp -R "$FALLBACK_MODEL" "$DEST/"
  cp "$FALLBACK_LABELS" "$DEST/labels/en_us.txt"
else
  echo "BirdNET Core ML model not found." >&2
  echo "Clone BirdNET-CoreML or run Tools/CoreMLSpike/scripts/setup-model.sh first." >&2
  exit 1
fi

echo "Bundled model: $DEST/audio-model-fp16.mlpackage"
echo "Bundled labels: $DEST/labels/en_us.txt"
