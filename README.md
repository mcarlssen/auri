<p align="center">
  <img src="Auri/Resources/Assets.xcassets/auri_logo.imageset/auri_logo.jpg" alt="Auri logo" width="220">
</p>

# Auri

Auri is a macOS menu bar app that listens for bird calls in real time, identifies species with BirdNET, and alerts you when something interesting shows up. It runs BirdNET in-process via Core ML — no Python server required.

**Requirements:** macOS 15.0 or later

## Features

- **Live monitoring** — microphone or system audio (BlackHole), with a scrolling mel spectrogram and adjustable input gain
- **Push notifications** — per-species cooldown so all-day singers do not spam you; hourly rate limit
- **Offline analysis** — analyze saved recordings (WAV, MP3, M4A, etc.) with overlapping windows and timeline-based cooldown
- **Recognition history** — persistent log across sessions, searchable and sortable by date, count, rarity, or name
- **Ignore list** — suppress common species you do not need alerts for
- **Location filtering** — optional regional checklist via eBird API; flags unusual species and requires +10% confidence for out-of-range detections
- **eBird helper** — unique species list since your last "Clear recent", with copy-to-clipboard and a link to the submission page

## Screenshots

The main window has tabs for Monitor, Offline, History, Ignore List, eBird, and Settings. The menu bar extra provides quick status and controls.

<img width="1243" height="751" alt="auri_newdash" src="https://github.com/user-attachments/assets/1f5f2c18-fadf-4e7c-8838-6bcbea4a493f" />

## Getting started

### Build from source

1. Clone the repository:

   ```bash
   git clone https://github.com/mcarlssen/auri.git
   cd auri
   ```

2. Download the BirdNET Core ML model (~46 MB):

   ```bash
   ./scripts/setup-birdnet-model.sh
   ```

   This copies `audio-model-fp16.mlpackage` and `en_us.txt` labels into `Auri/Resources/BirdNet/`. The script looks for a local [BirdNET-CoreML](https://github.com/gioneill/BirdNET-CoreML) checkout or the spike tool's model cache.

3. Open `Auri.xcodeproj` in Xcode and build (⌘B) or run (⌘R).

### First launch

1. Grant microphone access when prompted.
2. Adjust **confidence threshold** in Settings (default 60%).
3. Optionally enable **Location & rarity** and enter a free [eBird API key](https://ebird.org/api/keygen) for regional filtering.
4. Start listening from the Monitor tab or the menu bar popover.

## How it works

```
Microphone / system audio
  → 3-second windows @ 48 kHz
  → BirdNET Core ML (top-10 candidates per window)
  → threshold, ignore list, location filter, cooldown
  → notifications + history
```

BirdNET identifies up to 6,521 species from the bundled `en_us` label set. Inference runs on Apple silicon in roughly 30–50 ms per window (M1 baseline).

Location filtering uses eBird regional checklists post-inference. The audio model itself does not accept location or date inputs — Merlin's metadata model is not included in this Core ML conversion.

## Project structure

```
auri/
├── Auri/
│   ├── App/              # Entry point, menu bar, app delegate
│   ├── Audio/            # Capture, spectrogram, offline file loading
│   ├── Core/             # Settings, cooldown, history, eBird regional service
│   ├── Models/           # Detection and rarity types
│   ├── Server/           # BirdNetCoreMLRecognizer
│   ├── UI/               # SwiftUI views and view model
│   └── Resources/        # BirdNET model, assets, Info.plist
├── scripts/              # Model setup
├── Tools/CoreMLSpike/    # CLI benchmark tool
└── docs/                 # Design specs and spike results
```

## Attribution

- **BirdNET** — acoustic classification model ([BirdNET](https://birdnet.cornell.edu/)); Core ML conversion by [gioneill/BirdNET-CoreML](https://github.com/gioneill/BirdNET-CoreML)
- **eBird** — regional species data provided by [eBird.org](https://ebird.org), a project of the Cornell Lab of Ornithology

## Development

Enable **Debug logging** in Settings → Developer to see timestamped recognition output in Console (`[BirdNet]` prefix).

Benchmark inference without the app:

```bash
cd Tools/CoreMLSpike
./scripts/setup-model.sh
swift run -c release CoreMLSpike \
  --model Models/audio-model-fp16.mlpackage \
  --labels Models/labels/en_us.txt \
  --audio /path/to/recording.wav
```

## Acknowledgments

Built for birders who want a lightweight, always-on listener on the Mac — especially useful for overnight recordings and offline review when the yard is quiet.
