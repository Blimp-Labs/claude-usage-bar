// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageBar",
            path: "Sources/ClaudeUsageBar",
            resources: [
                .process("anime-mecha-art-wallpaper.webp")
            ]
        )
    ]
)
