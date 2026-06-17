// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OneDiscovery",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "OneDiscovery",
            targets: ["OneDiscovery"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/avgx/DebugThings.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "OneDiscovery",
            dependencies: [
                .product(name: "DebugThings", package: "DebugThings"),
            ]
        ),
        .testTarget(
            name: "OneDiscoveryTests",
            dependencies: ["OneDiscovery"],
            resources: [.process("Fixtures")]
        ),
    ]
)
