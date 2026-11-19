// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-opencode",
    platforms: [
        // Apple OS baselines (enabling Swift 6 Synchronization across all Apple targets).
        // Linux, Windows, Android, FreeBSD, and WASI targets build without restriction.
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // Pure portable libraries (all Swift platforms including iOS, Android, Windows, Linux, FreeBSD, WASI)
        .library(name: "OpenCodeUtil", targets: ["OpenCodeUtil"]),
        .library(name: "OpenCodeSchema", targets: ["OpenCodeSchema"]),
        .library(name: "OpenCodeProtocol", targets: ["OpenCodeProtocol"]),
        .library(name: "OpenCodePlatform", targets: ["OpenCodePlatform"]),
        .library(name: "OpenCodeAI", targets: ["OpenCodeAI"]),
        .library(name: "OpenCodeClient", targets: ["OpenCodeClient"]),

        // Runtime / Host libraries & Unified SDK
        .library(name: "OpenCodeCore", targets: ["OpenCodeCore"]),
        .library(name: "OpenCodeServer", targets: ["OpenCodeServer"]),
        .library(name: "OpenCodeSDK", targets: ["OpenCodeSDK"]),
        .library(name: "OpenCodeTUI", targets: ["OpenCodeTUI"]),

        // Executables
        .executable(name: "opencode", targets: ["OpenCodeCLI"]),
        .executable(name: "opencode-parity-runner", targets: ["OpenCodeParityRunner"]),
    ],
    dependencies: [
        .package(path: "Packages/OpenTUI"),
    ],
    targets: [
        // MARK: - Tier 1: Pure Portable Foundation (No OS-specific runtime dependencies)
        .target(
            name: "OpenCodeUtil",
            dependencies: []
        ),
        .target(
            name: "OpenCodeSchema",
            dependencies: ["OpenCodeUtil"]
        ),
        .target(
            name: "OpenCodeProtocol",
            dependencies: ["OpenCodeSchema"]
        ),

        // MARK: - Cross-Platform OS Abstraction Layer
        .target(
            name: "OpenCodePlatform",
            dependencies: ["OpenCodeUtil"]
        ),

        // MARK: - Tier 2: Client, AI Providers & Core Agent Runtime
        .target(
            name: "OpenCodeClient",
            dependencies: ["OpenCodeSchema", "OpenCodeProtocol", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeAI",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeCore",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeAI", "OpenCodePlatform"]
        ),

        // MARK: - Tier 3: Server, SDK, TUI & CLI Surfaces
        .target(
            name: "OpenCodeServer",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeProtocol", "OpenCodeCore", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeSDK",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeProtocol", "OpenCodeClient", "OpenCodeCore", "OpenCodeServer"]
        ),
        .target(
            name: "OpenCodeTUI",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeClient",
                "OpenCodePlatform",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUIKeymap", package: "OpenTUI"),
                .product(name: "OpenTUILayout", package: "OpenTUI"),
                .product(name: "OpenTUIRenderables", package: "OpenTUI"),
                .product(name: "OpenTUITerminal", package: "OpenTUI"),
                .product(name: "OpenTUIView", package: "OpenTUI"),
            ]
        ),
        .executableTarget(
            name: "OpenCodeCLI",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeTUI",
            ]
        ),

        // MARK: - Differential Parity Subject Runner
        .executableTarget(
            name: "OpenCodeParityRunner",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeCore",
            ]
        ),

        // MARK: - Test Suites
        .testTarget(
            name: "OpenCodeUtilTests",
            dependencies: ["OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeSchemaTests",
            dependencies: ["OpenCodeSchema", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeProtocolTests",
            dependencies: ["OpenCodeProtocol", "OpenCodeSchema", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodePlatformTests",
            dependencies: ["OpenCodePlatform", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeParityTests",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeProtocol", "OpenCodePlatform"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
