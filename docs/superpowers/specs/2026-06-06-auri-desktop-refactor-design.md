# Auri Desktop Refactor Design

## Summary

Split Auri into a **Dock-visible desktop app** with a hidden-at-launch main window and a **slim menubar popover** for quick server/listening controls. All runtime state stays in a single shared `BirdDetectionViewModel`.

## Decisions

| Topic | Decision |
|-------|----------|
| App presence | Normal Dock app (`LSUIElement` removed) |
| Main window at launch | **Hidden** — user opens via menubar **Open** or Dock icon |
| Menubar popover | Kept; slim remote control only |
| Settings location | Tab inside main window (remove separate Settings window) |
| State ownership | One `BirdDetectionViewModel` shared by popover + main window |
| eBird | Batch submission tab (extends current browser + clipboard flow) |
| Ignore list | Tab with suppression counters per species |

Unchanged from prior spec: bundle ID `com.x38.auri`, BirdNET Python server on localhost:8080, 48 kHz mono inference, user-selectable audio input, notification + ignore-list pipeline.

## App shell

```
AuriApp
├── @StateObject BirdDetectionViewModel (single instance)
├── MenuBarExtra — slim popover
│   ├── Server status dot + Start/Stop Server
│   ├── Listening status dot + Start/Stop Listening
│   └── Open → brings main window forward (NSApp.activate + openWindow)
└── Window("Auri", id: "main") — defaultLaunchBehavior: suppressed/hidden
    └── MainWindowView (TabView)
        ├── Monitor
        ├── Ignore List
        ├── eBird
        └── Settings
```

### Info.plist

- Remove `LSUIElement` (or set `false`).
- App appears in Dock and receives standard app menu bar when any window is key (or always, per macOS default for non-agent apps).

### Launch sequence

1. App launches → `BirdDetectionViewModel.bootstrapIfNeeded()` runs once (server auto-start, optional start-listening-at-login unchanged).
2. Main window is **not** shown.
3. Menubar icon is available; popover shows server/listening controls.
4. User clicks **Open** (or Dock icon) → main window appears; server/listening state unchanged.

### Quit behavior

- Closing main window does **not** quit the app.
- Quit via app menu or ⌘Q → `AppDelegate` calls `viewModel.shutdown()` (existing).

## Menubar popover (slim)

**Keep:**

- Header with short status line (`statusMessage`)
- Server row: indicator + label + Start/Stop Server
- Listening row: green/red indicator + label + Start/Stop Listening
- **Open** button

**Remove from popover:**

- Detection list and scroll area
- Input level / waveform
- Test injection button
- Settings button (settings live in main window)
- Separate Settings `Window` scene

Popover fixed size: ~360×180 (approx.), no layout shift on detections.

## Main window

Default size ~900×640, resizable. `TabView` with four tabs.

### Tab 1: Monitor

- **Live waveform** — scrolling view of recent audio peaks (see Audio changes below).
- **Detection feed** — full `DetectionCardView` list (reuse); Ignore + Submit to eBird per card.
- Optional header: server/listening status summary (read-only mirrors popover state).

### Tab 2: Ignore List

- Reuse `IgnoreListSettingsView` for add/remove species.
- **Suppression counters** — per ignored species, show count of detections suppressed (not notified) since app launch or persistently (see Data model).
- Display: species name, times suppressed, Remove button.

### Tab 3: eBird

- Multi-select from recent detections (checkboxes or list selection).
- Shared fields: date, location, method, notes (reuse patterns from `EBirdFormView`).
- **Submit selected** — for each detection, open browser / copy summary (same as current single-submit behavior, applied in batch with user confirmation).

### Tab 4: Settings

- Move entire current `SettingsView` content here (General, Recording, Detection, Notifications).
- Remove standalone Settings window and `@Environment(\.openSettings)` usage.

## Shared runtime (`BirdDetectionViewModel`)

No split into multiple view models. Extend existing type:

| Addition | Purpose |
|----------|---------|
| `waveformSamples: [Float]` | Ring buffer for Monitor tab (~1–2 s of downsampled peaks) |
| `suppressedCounts: [String: Int]` | Key = common name; increment when ignore list blocks a recognition |
| `openMainWindow()` | Helper called from popover (activation + openWindow) |

Existing properties unchanged: `detections`, `serverState`, `isListening`, settings, species, etc.

## Audio changes (`AudioHandler`)

Current `level: Float` (RMS) is insufficient for waveform.

- Maintain a fixed-size ring buffer (e.g. 512–1024 downsampled peak values).
- On each processed buffer, append normalized peak(s) and publish to `@Published waveformSamples` on MainActor (throttle UI updates to ~30 fps if needed).
- Monitor tab renders with `Canvas` or `Path` — no new dependencies.

## Ignore suppression counters

In `handleRecognition`, when `ignoreList.isSpeciesIgnored` returns true **and** confidence ≥ threshold (i.e. would have been a detection otherwise):

```swift
suppressedCounts[response.bird, default: 0] += 1
```

Persist in `UserDefaults` keyed by species name (and optionally ID) so counts survive restarts. Reset per-species optional later (out of scope for v1 unless requested).

## eBird batch flow

1. User selects N detections in eBird tab.
2. Fills shared metadata once.
3. On submit: sequential or grouped clipboard + browser open per detection (v1: one combined summary or step through — implement as sequential with alert showing progress).

Reuse `EBirdFormView` submission logic extracted into a shared helper.

## File plan (new / moved)

| File | Action |
|------|--------|
| `UI/MainWindowView.swift` | New — TabView shell |
| `UI/MonitorView.swift` | New — waveform + detections |
| `UI/IgnoreListTabView.swift` | New — ignore list + counters |
| `UI/EBirdBatchView.swift` | New — multi-submit |
| `UI/MenuBarView.swift` | Slim down |
| `UI/SettingsView.swift` | Adapt for tab (remove Done/dismiss toolbar) |
| `App/AuriApp.swift` | Add main Window, remove Settings window, defaultLaunchBehavior |
| `Resources/Info.plist` | Remove LSUIElement |
| `Audio/AudioHandler.swift` | Waveform ring buffer |
| `Core/Settings.swift` | Persist suppressedCounts |
| `UI/ViewModel/BirdDetectionViewModel.swift` | Counters, waveform passthrough, openMainWindow |

## Out of scope (v1)

- Dock menu customization beyond system default
- Waveform frequency/spectrogram analysis
- eBird API direct integration (still browser + clipboard)
- Removing menubar icon entirely

## Success criteria

- Launch: Dock icon visible, no main window, menubar popover works.
- Start server + listening from popover; close popover; state persists.
- Open main window: waveform animates while listening; detections appear in Monitor tab.
- Ignore a species via card or Ignore tab; future hits increment suppression counter, no notification.
- eBird tab submits multiple selected detections.
- All settings editable in Settings tab; no separate settings window.

## Migration notes

- Existing `UserDefaults` keys unchanged.
- Users upgrading lose nothing; first open of main window is manual (expected).
