// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RateFollower",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RateFollower", path: "Sources/RateFollower"),
    ]
)
