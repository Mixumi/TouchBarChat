// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TouchBarChat",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TouchBarChat", targets: ["TouchBarChat"])
    ],
    targets: [
        .executableTarget(
            name: "TouchBarChat",
            path: "Sources/TouchBarChat",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TouchBarChatTests",
            dependencies: ["TouchBarChat"],
            path: "Tests/TouchBarChatTests"
        )
    ]
)
