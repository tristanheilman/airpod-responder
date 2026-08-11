// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodResponder",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "NavigatorCore"),
        .testTarget(name: "NavigatorCoreTests", dependencies: ["NavigatorCore"]),
    ]
)
