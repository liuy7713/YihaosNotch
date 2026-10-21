// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YihaosNotch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "YihaosNotch",
            path: "Sources/YihaosNotch"
        )
    ]
)
