// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnowForecastKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SnowForecastKit",
            targets: ["SnowForecastKit"]
        ),
    ],
    targets: [
        .target(
            name: "SnowForecastKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "SnowForecastKitTests",
            dependencies: ["SnowForecastKit"]
        ),
    ]
)
