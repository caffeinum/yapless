// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Yapless",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "yapless", targets: ["VoiceToText"])
    ],
    dependencies: [
        // Command line argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Streaming ASR (parakeet on CoreML/ANE) for live insertion
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceToText",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoiceToText",
            swiftSettings: [
                .unsafeFlags(["-enable-bare-slash-regex", "-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "VoiceToTextTests",
            dependencies: ["VoiceToText"],
            path: "Tests/VoiceToTextTests"
        )
    ]
)
