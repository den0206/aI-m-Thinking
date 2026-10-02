// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ImThinking",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ImThinking", targets: ["ImThinking"])
    ],
    targets: [
        .executableTarget(
            name: "ImThinking",
            path: "Sources/ImThinking"
        )
    ]
)
