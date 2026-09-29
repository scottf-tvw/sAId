// swift-tools-version: 6.1
// sAId — push-to-talk dictation for Apple Silicon.
// Two resident engines: Qwen3-ASR (final text, via speech-swift) and
// Moonshine mediumStreaming (live HUD preview, via moonshine-swift).
import PackageDescription

let package = Package(
    name: "sAId",
    platforms: [.macOS(.v15)],   // speech-swift needs MLState (macOS 15+)
    products: [
        .executable(name: "sAId", targets: ["sAId"]),
    ],
    dependencies: [
        // Qwen3-ASR (MLX + CoreML) — Apache-2.0. Pin to a commit before v1.0 (see HANDOFF).
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
        // Moonshine Voice — ships Moonshine.xcframework as a binary target.
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", from: "0.1.5"),
    ],
    targets: [
        .executableTarget(
            name: "sAId",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MoonshineVoice", package: "moonshine-swift"),
            ],
            path: "Sources/sAId"
        ),
        .testTarget(
            name: "sAIdTests",
            dependencies: ["sAId"],
            path: "Tests/sAIdTests"
        ),
    ]
)
