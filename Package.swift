// swift-tools-version: 6.2
// (6.2 for `isolated deinit`; an older compiler fails with a confusing syntax error.)
import PackageDescription

let package = Package(
    name: "YihaosNotch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "YihaosNotch",
            path: "Sources/YihaosNotch"
        ),
        // Run with scripts/check.sh. Release builds (build.sh) never build this target.
        .testTarget(
            name: "YihaosNotchTests",
            dependencies: ["YihaosNotch"],
            path: "Tests/YihaosNotchTests"
        ),
    ]
)
