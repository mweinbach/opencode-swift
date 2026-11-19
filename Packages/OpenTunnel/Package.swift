// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenTunnel",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "OpenTunnelClient", targets: ["OpenTunnelClient"]),
    ],
    targets: [
        .target(
            name: "OpenTunnelClient",
            dependencies: []
        ),
        .testTarget(
            name: "OpenTunnelClientTests",
            dependencies: ["OpenTunnelClient"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
