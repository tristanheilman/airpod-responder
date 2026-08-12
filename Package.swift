// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodResponder",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "NavigatorCore"),
        .target(name: "NavigatorAudio", dependencies: ["NavigatorCore"]),
        .target(name: "NavigatorIO", dependencies: ["NavigatorCore", "NavigatorAudio"]),
        .executableTarget(name: "ReplayHarness", dependencies: ["NavigatorCore"]),
        .executableTarget(
            name: "navigator",
            dependencies: ["NavigatorCore", "NavigatorAudio", "NavigatorIO"]),
        .executableTarget(
            name: "navigator-hook", dependencies: ["NavigatorCore", "NavigatorIO"]),
        .testTarget(name: "NavigatorCoreTests", dependencies: ["NavigatorCore"]),
        .testTarget(name: "NavigatorAudioTests", dependencies: ["NavigatorAudio"]),
        .testTarget(
            name: "NavigatorIOTests", dependencies: ["NavigatorIO", "NavigatorAudio"]),
    ]
)
