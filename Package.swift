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
        // The stdio command agents start; it relays to the running app over a Unix socket.
        .executable(name: "singularity-mcp", targets: ["singularity-mcp"]),
    ],
    dependencies: [
        // Terminal emulator for terminal tabs. Pinned to the 1.99 line (v1.20 pulls in a benchmark
        // package with jemalloc by default). Exact version is locked in Package.resolved.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.3"),
        // Small HTTP server (no further dependencies) for each Space's artifact server.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.27.1"),
        // The official MCP Swift SDK (pre-1.0: read release notes before raising the minor version).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
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
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // No dependencies on purpose: it only copies bytes between stdio and the app's socket.
        .executableTarget(name: "singularity-mcp"),

        .testTarget(
            name: "SingularityCoreTests",
            dependencies: ["SingularityCore"]
        ),
    ]
)
