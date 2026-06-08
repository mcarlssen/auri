# Core ML Spike Results (2026-06-07)

## Goal

Validate whether BirdNET 2.4 can run in-process via Core ML on Apple silicon fast enough to replace the Python TensorFlow server path.

## Setup

- Model: [gioneill/BirdNET-CoreML](https://github.com/gioneill/BirdNET-CoreML) `audio-model-fp16.mlpackage` (v2.4, FP16, ~46 MB)
- Spike tool: `Tools/CoreMLSpike` (Swift CLI)
- Test audio: `crow.wav` from BirdNET-CoreML verification suite
- Machine: M1 Mac (same host as prior TF benchmarks)

## Results

| Runtime | Load | Inference (median) | Top-1 on crow.wav |
|---------|------|--------------------|-------------------|
| Python `birdnet` TF CPU | n/a (server warmup ~30–50s first call) | **~7,870 ms** (3 warm runs) | n/a (silence benchmark) |
| Core ML Swift (`computeUnits: all`) | 1,866 ms | **41 ms** | American Crow @ 0.97 |
| Core ML Swift (`computeUnits: cpuOnly`) | 416 ms | **30 ms** | (silence) |

Core ML is roughly **190× faster** than the current Python TF CPU path for a single 3-second window.

Accuracy sanity check: crow.wav top prediction is American Crow at 0.97 confidence — matches expected species.

## Implications

1. **Feasible** — realtime inference is achievable on M1 without a Python server.
2. **Preprocessing is embedded** — the converted model accepts raw 48 kHz mono waveform (144,000 samples). No separate mel/FFT Swift port needed for inference (spectrogram layer is inside the model).
3. **Bundling cost** — ~46 MB FP16 model + labels in the app bundle.
4. **Maintenance risk** — community conversion, not official BirdNET; must re-verify on model updates.

## Implementation status (2026-06-07)

Completed in app:

1. `BirdNetCoreMLRecognizer` — in-process Core ML inference actor
2. `BirdDetectionViewModel` — uses recognizer directly (Python server removed)
3. Bundled `audio-model-fp16.mlpackage` + `en_us.txt` in app resources (~46 MB model)

Optional future work: metadata model for location/time filtering.

## How to reproduce

```bash
git clone --depth 1 https://github.com/gioneill/BirdNET-CoreML.git /tmp/BirdNET-CoreML
cd Tools/CoreMLSpike
./scripts/setup-model.sh
swift run -c release CoreMLSpike \
  --model Models/audio-model-fp16.mlpackage \
  --labels Models/labels/en_us.txt \
  --audio /tmp/BirdNET-CoreML/verification/crow.wav \
  --runs 5
```

Python TF baseline (from repo root, `.venv311`):

```bash
source .venv311/bin/activate
python3 -c "
import time, numpy as np, birdnet
m = birdnet.load('acoustic','2.4','tf')
sr = int(m.get_sample_rate())
x = np.zeros(sr*3, dtype=np.float32)
m.predict_arrays((x, sr), top_k=1, default_confidence_threshold=0.0, batch_size=1)
t0 = time.perf_counter()
m.predict_arrays((x, sr), top_k=1, default_confidence_threshold=0.0, batch_size=1)
print(int((time.perf_counter()-t0)*1000), 'ms')
"
```
