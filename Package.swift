// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodResponder",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "NavigatorCore"),
        .target(name: "NavigatorIO", dependencies: ["NavigatorCore"]),
        .executableTarget(name: "ReplayHarness", dependencies: ["NavigatorCore"]),
        .executableTarget(
            name: "navigator", dependencies: ["NavigatorCore", "NavigatorIO"]),
        .executableTarget(
            name: "navigator-hook", dependencies: ["NavigatorCore", "NavigatorIO"]),
        .testTarget(name: "NavigatorCoreTests", dependencies: ["NavigatorCore"]),
        .testTarget(name: "NavigatorIOTests", dependencies: ["NavigatorIO"]),
    ]
)
