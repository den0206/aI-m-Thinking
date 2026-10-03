// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "AImThinking",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "AImThinking", targets: ["AImThinking"])
    ],
    targets: [
        .executableTarget(
            name: "AImThinking",
            path: "Sources/AImThinking"
        ),
        .testTarget(
            name: "AImThinkingTests",
            dependencies: ["AImThinking"],
            path: "Tests/AImThinkingTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
