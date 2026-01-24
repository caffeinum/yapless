// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "voice-to-text", targets: ["VoiceToText"])
    ],
    dependencies: [
        // Command line argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceToText",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
