// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanDrop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LanDropCore", targets: ["LanDropCore"]),
        .executable(name: "LanDrop", targets: ["LanDropApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "LanDropCore"),
        .executableTarget(
            name: "LanDropApp",
            dependencies: ["LanDropCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "LanDropCoreTests", dependencies: ["LanDropCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
