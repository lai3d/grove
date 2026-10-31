// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Grove",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Grove", targets: ["Grove"]),
        .library(name: "GroveCore", targets: ["GroveCore"]),
    ],
    targets: [
        // UI-independent Git engine: process runner, porcelain parsers,
        // repository actor, commit-graph lane layout.
        .target(name: "GroveCore"),
        // SwiftUI shell + AppKit heavy views (commit table, diff view).
        .executableTarget(name: "Grove", dependencies: ["GroveCore"]),
        .testTarget(name: "GroveCoreTests", dependencies: ["GroveCore"]),
    ]
)
