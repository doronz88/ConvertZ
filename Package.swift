// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConvertZ",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ConvertZCore"),
        .executableTarget(name: "ConvertZ", dependencies: ["ConvertZCore"]),
        .testTarget(name: "ConvertZCoreTests", dependencies: ["ConvertZCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
