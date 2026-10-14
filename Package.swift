// swift-tools-version: 6.0

import PackageDescription

// xtool stamps LC_BUILD_VERSION from the deployment target. Override only the
// recorded SDK version so iOS 26 enables Liquid Glass while minOS stays iOS 17.
// Codemagic strips this Linux-only override before generating an Xcode project.
let liquidGlassSDKStamp: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-platform_version",
        "-Xlinker", "ios",
        "-Xlinker", "17.0",
        "-Xlinker", "26.0",
    ])
]

let package = Package(
    name: "CodexMeter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodexMeter", targets: ["CodexMeter"]),
        .library(name: "CodexMeterWidget", targets: ["CodexMeterWidget"]),
    ],
    targets: [
        .target(
            name: "CodexMeterCore",
            swiftSettings: [.unsafeFlags(["-disable-batch-mode"])]
        ),
        .target(
            name: "CodexMeter",
            dependencies: ["CodexMeterCore"],
            swiftSettings: [.unsafeFlags(["-disable-batch-mode"])],
            linkerSettings: liquidGlassSDKStamp
        ),
        .target(
            name: "CodexMeterWidget",
            dependencies: ["CodexMeterCore"],
            swiftSettings: [.unsafeFlags(["-disable-batch-mode"])],
            linkerSettings: liquidGlassSDKStamp
        ),
        .target(name: "TestSupport", dependencies: ["CodexMeterCore"], path: "Tests/Support"),
        .testTarget(name: "CodexMeterTests", dependencies: ["CodexMeterCore", "TestSupport"]),
    ]
)
