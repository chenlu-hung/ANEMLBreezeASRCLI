// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "breeze-asr",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.1.2")),
        .package(url: "https://github.com/dagronf/SwiftSubtitles", from: "2.2.0"),
        // Native (pure-Swift) edge-tts client for cloud dub TTS — no Python, no external binary.
        .package(url: "https://github.com/herrkaefer/SwiftEdgeTTS", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "breeze-asr",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "SwiftSubtitles", package: "SwiftSubtitles"),
                .product(name: "SwiftEdgeTTS", package: "SwiftEdgeTTS")
            ],
            path: "Sources/breeze-asr"
        )
    ]
)
