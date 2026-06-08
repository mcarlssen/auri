Target Experience:

Install once, listen forever (it runs in the background)
Push notifications when birds are detected
Clean, intuitive UI for sound exploration
Manual eBird observation submission
2. Target Architecture
Tech Stack:

Framework: SwiftUI (Apple-native, modern, clean ecosystem)
App Category: .app bundle, full-featured app (not just a mini-app)
Audio Input: AVAudioEngine + installTap()
Audio Processing: AudioKit-style resampling (BlackHole approach)
BirdNET: Python REST API server (localhost:8080)
Notifications: NSUserNotificationCenter + SwiftUI
eBird Submission: Manual form (WhatsApp to Merlin is not API-accessible)
Recommended Project Structure:

birdwatcher/
├── birdwatcher.xcodeproj/
│   └── project.pbxproj
├── Birdwatcher/
│   ├── Birds/
│   │   ├── Models/
│   │   │   ├── Bird.swift
│   │   │   ├── BirdDetection.swift
│   │   │   └── NotificationPayload.swift
│   │   └── Assets/
│   ├── Audio/
│   │   ├── AudioEngine/
│   │   │   └── AudioHandler.swift
│   │   ├── Recording/
│   │   │   └── RecordingController.swift
│   │   └── AudioFormat.swift
│   ├── Server/
│   │   ├── BirdNetServer.swift
│   │   └── BirdNetClient.swift
│   ├── Core/
│   │   ├── Theme/
│   │   ├── Delay/
│   │   ├── AddDelay.swift
│   │   ├── IgnoreList.swift
│   │   └── Cooldown.swift
│   ├── UI/
│   │   ├── HomeView.swift
│   │   ├── SettingsView.swift
│   │   ├── NotificationCardView.swift
│   │   ├── Submitter.swift
│   │   └── ViewModel/
│   │       └── BirdDetectionViewModel.swift
│   └── App/
│       ├── AppEntry.swift
│       ├── AppDelegate.swift
│       └── main.swift
├── birdwatcher.api/
│   ├── birdnet/api/
│   │   ├── api.py
│   │   ├── analyzer.py
│   │   └── models.py
│   └── server.py
├── birdwatcher.bundle/
│   ├── Resources/
│   ├── icon.icns
│   ├── AppIcon.appiconset/
│   ├── Info.plist
│   ├── LaunchArguments.plist
│   └── entitlements/
│       └── com.glasserbard.BirdWatcher.entitlements
├── config.js
└── requirements.txt
3. Audio System
Requirements:

Input: Hardware microphone, always capture system audio (not just built-in mic)
Format: Float32, 22050 Hz, 1 channel
Latency: Target 10-50ms (capture → resample → process)
Permissions: Request at launch, fallback to error if denied
Implementation:

// AudioEngine.swift
class AudioHandler {
    var engine: AVAudioEngine
    var resampler: AudioKit.MixingEngine
    var processBusCount: Int64 = 1
    var birdNetResponseBufferCount: Int32 = 0
    
    func start() throws {
        try audioInputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: audioFormat
        ) { buffer, time in
            buffer.frameLength = UInt32(buffer.frameLength)
            var samples: Float32 = []
            var index = 0
            buffer.bindCopies(to: &samples, from: &index)
            //...
        }
        engine.prepare()
        engine.start()
    }
}
4. Server (Python/BirdNET)
Endpoints:

# API Endpoints
POST /api/v1/bird/recognize
POST /api/v1/bird/recognize_streaming
# Response Format
{
  "bird": "Bobolink",
  "id": 10636,
  "confidence": 0.89,
  "source": 1,
  "score": 0.89,
  "state": 1.6,
  "time_ms": 123
}
API Constraints:

Running on localhost:8080
Minimum 10ms response time
Reads BirdNET model files from /birdnet/models/
Uses feature vectors: 1024 elements, 558 bins
5. Core Logic
AddDelay (Cooldown):

struct AddDelay: OptionProtocol {
    static var initial: Int = 5
    static var minimum: Int = 5
    static var minimumOther: Int = 1
    static var maximum: Int = 15
    static var bandMultiplier: Int = 1
    
    static func compute(for delay: Int) -> Int {
        let minimum = delay < minimum ? minimum : delay
        let maximum = delay < maximum ? maximum : delay
        let random = Int.random(in: 0...maximum)
        return minimum + random
    }
}
Ignore List:

struct IgnoreList {
    var speciesIDs: [Int]
    var speciesNames: [String]
    
    func isSpeciesIgnored(_ species: Bird) -> Bool {
        species.id == speciesIDs.contains(where: $0 == species.id) ||
        species.name == speciesNames.contains(where: $0 == species.name)
    }
}
6. Notifications
Bird Card Notification:

@NSApplication.DefinesCustomNotification
struct NotificationCard {
    var birdName: String
    var scientificName: String
    var confidence: Double
    var timestamp: Date
    var sourceAudio: String
    
    var birdId: Int?
    var videoResource: URL?
    var soundResource: URL?
    var audioResource: URL?
    var thumbnailResource: URL?
}
Notification Settings:

Threshold: Minimum confidence score (default 0.6)
Ignore list: Species to suppress
Cooldown: Minimum seconds between notifications (default 5)
Enable/Disable toggle
Sound preference
Frequency (number of times per hour)
7. eBird Submission
Manual Form:

Bird ID (from notification or manual selection)
Observed Date
Location (auto-filled from system, editable)
Method (direct ID, audio recording)
Notes (optional)
Submit Button:

Opens WhatsApp to Merlin's eBird account (no API available)
Or opens browser to eBird submission page
Shows confirmation dialog
eBird API (Future Enhancement):

API endpoints for eBird: /observations/search, /public/observations/
Supported eBird geolocation for USA
Minimum 10 locations from government database
Privacy-safe submission
8. Critical Implementation Details
AVAudioEngine Required Setup:

Set audioSessionCategory = .playAndRecord
audioSessionCategoryOptions = [.defaultMixerChannel, .duplicateIncomingMixerChannel]
audioSessionCategoryOptions = .defaultInput
audioSessionCategoryOptions = [.allowDeviceDefault]
Request permission in Info.plist: NSMicrophoneUsageDescription
Server Requirements:

Python 3.8+ with bottle and numpy
Runs on localhost:8080
Runs BirdNET model in background
REST API for live audio stream
Processing Pipeline:

AVAudioEngine captures input
Resampler converts to Float32
Feature extraction (Kaldi)
LDA (Linear Discriminant Analysis)
BirdNET prediction (neural network)
Return bird ID + confidence
Error Handling:

Microphone permission denied → app quits gracefully
Server not running → notify user, app continues but no detection
Network error → notify user, app continues but no detection
9. Critical UX Considerations
Notification Settings:

Dynamic threshold (0.0-1.0)
Frequency adjustment (per hour)
Ignore list
Cooldown (min 5s)
Sound preference
Home Screen:

Main status bar (recording on/off)
Audio waveform display
Current sound level
Recent detections
Detection Card:

Bird name (with emoji)
Scientific name
Confidence score
Time of detection
Easy-to-submit button
eBird Submission:

Beautiful form
Bird ID selector (all 300+ NA species)
Date picker
Location picker
Method selector (audio, direct ID)
Notes field
Submit button
Success/error feedback
10. Known Pitfalls & Solutions
Pitfall 1: Latency

Problem: Bird calls happen in milliseconds; app may not catch them

Solution:

Use installTap on Bus 0 (direct input capture)
Resample to minimal buffer size (512-1024 frames)
Target 10-50ms latency (realistic with BirdNET model)
Pitfall 2: Microphone Permission

Problem: User may deny permission or user may not have access to mic

Solution:

Request permission at launch
Graceful fallback if denied
Clear error message and suggestion
Pitfall 3: Server Crash

Problem: Python BirdNET server may crash on startup

Solution:

Check server status on app startup
Notify user if not running
Start server on demand (lazy loading)
Pitfall 4: Notification Permissions

Problem: App may be blocked from notifications

Solution:

Request notification permission in app flow
Graceful fallback if denied
11. Future Enhancements (Post-MVP)
Potential Future Features:

Batch analysis of recorded audio files
iOS companion app (future Apple API integration)
Offline mode (pre-download models)
Battery-saving mode (lower frequency checks)
Geolocation services (GPS-based bird migration tracking)
Machine learning model training (user data)
Export tracking data (CSV, GIS)
But NOT for MVP:

iOS app (no Apple API)
Cloud sync (privacy, complexity)
Wildcard detection (CPU/GPU heavy)
Advanced UI (keep it minimal for birding)
12. Final Recommendation
Your First Step:

Install Xcode (free, Apple developer account needed - $99)
Install Python 3.8+ (with Bottle, numpy)
Download BirdNET models (300+ NA species)
Set up BirdNET API server (localhost:8080)
Start with SwiftUI sample app (SwiftUI Playground or Example)
My Recommended MVP Scope:

SwiftUI home screen (simple, beautiful, minimal)
Audio capture (AVAudioEngine, Float32, 22050Hz)
BirdNET server (Python, localhost:8080)
Notification card (bird name, confidence, timestamp)
Ignore list (settings)
eBird submission (manual form)
No iOS integration (impossible)