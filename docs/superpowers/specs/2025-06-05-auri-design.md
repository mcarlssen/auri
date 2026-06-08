# Auri Design Spec

## Decisions

- Menu bar macOS app (`LSUIElement`)
- Bundle ID: `com.x38.auri`
- Audio: user-selectable input (built-in mic, BlackHole, any device)
- BirdNET server: Swift spawns bundled Python 3.11 venv
- eBird: browser submission with clipboard summary
- Inference: `birdnet` Python package (48 kHz model sample rate)

## Architecture

Swift menu bar app captures audio, resamples to 48 kHz float32 mono, sends 3-second windows to `POST /api/v1/bird/recognize`. Python Bottle server runs BirdNET via `predict_arrays`. Detections above threshold trigger macOS notifications and appear in the popover.

## Components

- `ServerManager`: spawn/monitor `backend/server.py`
- `AudioHandler`: `AVAudioEngine` tap + resample
- `BirdNetClient`: HTTP client for recognition + species list
- `DetectionPipeline`: threshold, ignore list, cooldown, notifications
- `MenuBarView` / `SettingsView` / `EBirdFormView`

## Error Handling

- Mic denied: show settings link, keep app alive
- Server down: warning badge + retry
- Notifications denied: in-app cards only
