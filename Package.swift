// swift-tools-version: 6.1
// sAId — push-to-talk dictation for Apple Silicon.
// One resident Moonshine mediumStreaming model serves final text and live HUD preview.
import PackageDescription

let package = Package(
    name: "sAId",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sAId", targets: ["sAId"]),
        .executable(name: "said-bench", targets: ["SaidBench"]),
    ],
    dependencies: [
        // Moonshine Voice — ships Moonshine.xcframework as a binary target.
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", exact: "0.1.5"),
    ],
    targets: [
        .target(name: "SaidEngine", dependencies: [.product(name: "MoonshineVoice", package: "moonshine-swift")]),
        .executableTarget(name: "SaidBench", dependencies: ["SaidEngine"], path: "Sources/SaidBench"),
        .executableTarget(
            name: "sAId",
            dependencies: ["SaidEngine"],
            path: "Sources/sAId"
        ),
        .testTarget(
            name: "sAIdTests",
            dependencies: ["sAId", "SaidEngine", "SaidBench"],
            path: "Tests/sAIdTests"
        ),
    ]
)
