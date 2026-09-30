// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanDrop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LanDropCore", targets: ["LanDropCore"]),
        .executable(name: "LanDrop", targets: ["LanDropApp"]),
    ],
    targets: [
        .target(name: "LanDropCore"),
        .executableTarget(name: "LanDropApp", dependencies: ["LanDropCore"]),
        .testTarget(name: "LanDropCoreTests", dependencies: ["LanDropCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
