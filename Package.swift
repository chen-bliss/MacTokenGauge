// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTokenGauge",
    platforms: [.macOS(.v14)],
    products: [.library(name: "GaugeCore", targets: ["GaugeCore"])],
    targets: [
        .target(name: "GaugeCore", path: "ChatGPTGauge",
                exclude: ["ChatGPTGaugeApp.swift", "Assets.xcassets", "AppIcon.icns"]),
        .testTarget(name: "GaugeCoreTests", dependencies: ["GaugeCore"], path: "Tests/GaugeCoreTests")
    ]
)
