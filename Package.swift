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
        .library(name: "OpenCodeRecorder", targets: ["OpenCodeRecorder"]),
        .library(name: "OpenCodeCore", targets: ["OpenCodeCore"]),
        .library(name: "OpenCodeServer", targets: ["OpenCodeServer"]),
        .library(name: "OpenCodeSDK", targets: ["OpenCodeSDK"]),
        .library(name: "OpenCodeTUI", targets: ["OpenCodeTUI"]),
        .library(name: "OpenCodeSimulation", targets: ["OpenCodeSimulation"]),
        .library(name: "OpenCodeGUIPlugins", targets: ["OpenCodeGUIPlugins"]),
        .library(name: "OpenCodeApp", targets: ["OpenCodeApp"]),
        .library(name: "OpenCodeCLIKit", targets: ["OpenCodeCLIKit"]),

        // Executables
        .executable(name: "opencode", targets: ["OpenCodeCLI"]),
        .executable(name: "opencode-app", targets: ["OpenCodeAppMain"]),
        .executable(name: "opencode-parity-runner", targets: ["OpenCodeParityRunner"]),
    ],
    dependencies: [
        .package(path: "Packages/OpenTUI"),
        .package(path: "Packages/OpenTunnel"),
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
            dependencies: ["OpenCodeUtil"],
            linkerSettings: [.linkedLibrary("Ws2_32", .when(platforms: [.windows]))]
        ),

        // MARK: - Tier 2: Client, AI Providers & Core Agent Runtime
        .target(
            name: "OpenCodeClient",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeProtocol", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeAI",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeRecorder",
            dependencies: ["OpenCodeUtil", "OpenCodePlatform"]
        ),
        .target(
            name: "OpenCodeCore",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeAI", "OpenCodePlatform"],
            resources: [.copy("Resources")]
        ),

        // MARK: - Tier 3: Server, SDK, TUI & CLI Surfaces
        .target(
            name: "OpenCodeServer",
            dependencies: ["OpenCodeUtil", "OpenCodeSchema", "OpenCodeProtocol", "OpenCodeCore", "OpenCodePlatform"],
            linkerSettings: [.linkedLibrary("Ws2_32", .when(platforms: [.windows]))]
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
                "OpenCodeProtocol",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodePlatform",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUIKeymap", package: "OpenTUI"),
                .product(name: "OpenTUILayout", package: "OpenTUI"),
                .product(name: "OpenTUIRenderables", package: "OpenTUI"),
                .product(name: "OpenTUITerminal", package: "OpenTUI"),
                .product(name: "OpenTUIView", package: "OpenTUI"),
            ],
            resources: [.copy("Resources")]
        ),
        .target(
            name: "OpenCodeSimulation",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeAI",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeTUI",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUIRenderables", package: "OpenTUI"),
            ]
        ),
        .target(
            name: "OpenCodeGUIPlugins",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeClient",
                "OpenCodeCore",
            ]
        ),
        .target(
            name: "OpenCodeApp",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeSDK",
                "OpenCodeTUI",
                "OpenCodeGUIPlugins",
                .product(name: "OpenTUICore", package: "OpenTUI"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "OpenCodeAppMain",
            dependencies: ["OpenCodeApp"]
        ),
        .target(
            name: "OpenCodeCLIKit",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeSDK",
                "OpenCodeTUI",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUITerminal", package: "OpenTUI"),
                .product(name: "OpenTunnelClient", package: "OpenTunnel"),
            ]
        ),
        .executableTarget(
            name: "OpenCodeCLI",
            dependencies: [
                "OpenCodeCLIKit",
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeSDK",
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
                "OpenCodeAI",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeTUI",
                "OpenCodeCLIKit",
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
            name: "OpenCodeAITests",
            dependencies: ["OpenCodeAI", "OpenCodeSchema", "OpenCodePlatform", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeClientTests",
            dependencies: ["OpenCodeClient", "OpenCodeProtocol", "OpenCodeSchema", "OpenCodePlatform", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeCoreTests",
            dependencies: ["OpenCodeCore", "OpenCodeAI", "OpenCodeSchema", "OpenCodePlatform", "OpenCodeUtil"],
            linkerSettings: [.linkedLibrary("Ws2_32", .when(platforms: [.windows]))]
        ),
        .testTarget(
            name: "OpenCodeServerTests",
            dependencies: ["OpenCodeServer", "OpenCodeSDK", "OpenCodeClient", "OpenCodeCore", "OpenCodeProtocol", "OpenCodeSchema", "OpenCodePlatform", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeTUITests",
            dependencies: [
                "OpenCodeTUI",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeProtocol",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeUtil",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUIKeymap", package: "OpenTUI"),
                .product(name: "OpenTUILayout", package: "OpenTUI"),
                .product(name: "OpenTUIRenderables", package: "OpenTUI"),
                .product(name: "OpenTUITerminal", package: "OpenTUI"),
                .product(name: "OpenTUIView", package: "OpenTUI"),
            ]
        ),
        .testTarget(
            name: "OpenCodeRecorderTests",
            dependencies: ["OpenCodeRecorder", "OpenCodePlatform", "OpenCodeUtil"]
        ),
        .testTarget(
            name: "OpenCodeSimulationTests",
            dependencies: [
                "OpenCodeSimulation",
                "OpenCodeServer",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeAI",
                "OpenCodeTUI",
                "OpenCodeProtocol",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeUtil",
                .product(name: "OpenTUICore", package: "OpenTUI"),
                .product(name: "OpenTUIRenderables", package: "OpenTUI"),
            ],
            linkerSettings: [.linkedLibrary("Ws2_32", .when(platforms: [.windows]))]
        ),
        .testTarget(
            name: "OpenCodeGUIPluginsTests",
            dependencies: [
                "OpenCodeGUIPlugins",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeProtocol",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeUtil",
            ]
        ),
        .testTarget(
            name: "OpenCodeAppTests",
            dependencies: [
                "OpenCodeApp",
                "OpenCodeGUIPlugins",
                "OpenCodeSDK",
                "OpenCodeServer",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeTUI",
                "OpenCodeProtocol",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeUtil",
                .product(name: "OpenTUICore", package: "OpenTUI"),
            ]
        ),
        .testTarget(
            name: "OpenCodeCLITests",
            dependencies: [
                "OpenCodeCLIKit",
                "OpenCodeSDK",
                "OpenCodeServer",
                "OpenCodeClient",
                "OpenCodeCore",
                "OpenCodeProtocol",
                "OpenCodeSchema",
                "OpenCodePlatform",
                "OpenCodeTUI",
                "OpenCodeUtil",
                .product(name: "OpenTunnelClient", package: "OpenTunnel"),
            ]
        ),
        .testTarget(
            name: "OpenCodeParityTests",
            dependencies: [
                "OpenCodeUtil",
                "OpenCodeSchema",
                "OpenCodeProtocol",
                "OpenCodePlatform",
                "OpenCodeAI",
                "OpenCodeCore",
                "OpenCodeServer",
                "OpenCodeTUI",
                "OpenCodeCLIKit",
            ],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
