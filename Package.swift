// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicWallpaperSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "AerialEncoderPOC", targets: ["AerialEncoderPOC"]),
        .executable(name: "EncoderCapabilityProbe", targets: ["EncoderCapabilityProbe"]),
        .executable(name: "TemporalSampleWriterPOC", targets: ["TemporalSampleWriterPOC"])
    ],
    targets: [
        .target(name: "SwitcherCore", path: "Sources/SwitcherCore"),
        .executableTarget(name: "AerialEncoderPOC", path: "Sources/AerialEncoderPOC"),
        .executableTarget(name: "EncoderCapabilityProbe", path: "Sources/EncoderCapabilityProbe"),
        .executableTarget(name: "TemporalSampleWriterPOC", path: "Sources/TemporalSampleWriterPOC"),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], path: "Tests/SwitcherCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
