// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacBootSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacBootSwitcher",
            path: "Sources/MacBootSwitcher"
        ),
        .testTarget(
            name: "MacBootSwitcherTests",
            dependencies: ["MacBootSwitcher"],
            path: "Tests/MacBootSwitcherTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
