// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoreMLSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CoreMLSpike",
            path: "Sources/CoreMLSpike"
        ),
    ]
)
