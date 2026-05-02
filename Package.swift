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
    targets: [
        .target(
            name: "OneDiscovery"
        ),
        .testTarget(
            name: "OneDiscoveryTests",
            dependencies: ["OneDiscovery"],
            resources: [.process("Fixtures")]
        ),
    ]
)
