// swift-tools-version: 6.0
//
// Singularity Browser is built with SwiftPM only (no Xcode project).
// `scripts/build-app.sh` wraps the `Singularity` executable into a signed .app bundle.

import PackageDescription

let package = Package(
    name: "Singularity",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Singularity", targets: ["Singularity"]),
    ],
    targets: [
        // Pure Swift: models, persistence, palette logic. No AppKit/WebKit, so it is unit-testable.
        .target(name: "SingularityCore"),

        // The app itself: SwiftUI views plus AppKit/WebKit glue.
        .executableTarget(
            name: "Singularity",
            dependencies: ["SingularityCore"]
        ),

        .testTarget(
            name: "SingularityCoreTests",
            dependencies: ["SingularityCore"]
        ),
    ]
)
