# Core ML Spike

Benchmark BirdNET 2.4 Core ML inference on macOS and compare latency to the Python TensorFlow server path.

## Setup

```bash
git clone --depth 1 https://github.com/gioneill/BirdNET-CoreML.git /tmp/BirdNET-CoreML
./scripts/setup-model.sh
```

This copies `audio-model-fp16.mlpackage` (~46 MB) and English labels into `Models/`. The model is gitignored; run the setup script after cloning this repo.

## Run

```bash
cd Tools/CoreMLSpike
swift run CoreMLSpike \
  --model Models/audio-model-fp16.mlpackage \
  --labels Models/labels/en_us.txt \
  --audio /tmp/BirdNET-CoreML/verification/crow.wav \
  --runs 5
```

Omit `--audio` to benchmark on 3 seconds of silence. Omit `--labels` to skip top-k decoding.

## What this proves

- Whether Core ML can run a 3-second BirdNET window in-process on Apple silicon
- Load time vs steady-state inference time
- Rough comparison to the current Python `birdnet` TF CPU baseline (~7–11s per window on M1)

## Model details

From [gioneill/BirdNET-CoreML](https://github.com/gioneill/BirdNET-CoreML):

- Input: mono waveform, 144,000 samples @ 48 kHz (3 seconds)
- Mel spectrogram preprocessing is embedded in the model
- Output: 6,522 species probabilities

## Next steps (if spike passes)

1. Port species decoding + thresholding to Swift
2. Replace `BirdNetClient` HTTP calls with in-process `MLModel` prediction
3. Optionally add metadata model for location filtering
4. Keep Python server as dev/fallback only
