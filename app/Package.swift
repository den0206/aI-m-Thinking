// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ImThinking",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "ImThinking", targets: ["ImThinking"])
    ],
    targets: [
        .executableTarget(
            name: "ImThinking",
            path: "Sources/ImThinking"
        ),
        .testTarget(
            name: "ImThinkingTests",
            dependencies: ["ImThinking"],
            path: "Tests/ImThinkingTests"
        )
    ]
)
