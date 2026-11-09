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
    dependencies: [
        // Terminal emulator for terminal tabs. Pinned to the 1.99 line (v1.20 pulls in a benchmark
        // package with jemalloc by default). Exact version is locked in Package.resolved.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.3"),
    ],
    targets: [
        // Pure Swift: models, persistence, palette logic. No AppKit/WebKit, so it is unit-testable.
        .target(name: "SingularityCore"),

        // The app itself: SwiftUI views plus AppKit/WebKit glue.
        .executableTarget(
            name: "Singularity",
            dependencies: [
                "SingularityCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),

        .testTarget(
            name: "SingularityCoreTests",
            dependencies: ["SingularityCore"]
        ),
    ]
)
