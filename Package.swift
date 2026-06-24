// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowTranslateCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FlowTranslateCore",
            targets: ["FlowTranslateCore"]
        )
    ],
    targets: [
        .target(
            name: "FlowTranslateCore"
        ),
        .testTarget(
            name: "FlowTranslateCoreTests",
            dependencies: ["FlowTranslateCore"]
        )
    ]
)
