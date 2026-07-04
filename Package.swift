// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AuriCore",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .target(
            name: "AuriCore",
            path: "Auri",
            sources: [
                "Core/Settings.swift",
                "Core/DotEnv.swift",
                "Core/Cooldown.swift",
                "Core/DetectionCorroborator.swift",
                "Core/ConfidenceRollingEstimator.swift",
                "Core/IgnoreList.swift",
                "Core/RecognitionHistoryStore.swift",
                "Core/RecognitionLogger.swift",
                "Models/Bird.swift",
                "Models/BirdDetection.swift",
                "Models/RarityInfo.swift",
                "Audio/AudioMeterStats.swift",
                "Audio/AudioWindowNormalizer.swift",
                "Audio/SpectrogramEngine.swift",
                "Audio/AudioFileLoader.swift",
                "Audio/WindowAccumulator.swift",
                "Server/BirdNetCoreMLRecognizer.swift",
                "UI/DetectionCardView.swift",
                "UI/SpectrogramView.swift"
            ]
        ),
        .testTarget(
            name: "AuriCoreTests",
            dependencies: ["AuriCore"],
            path: "Tests/AuriCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
