// swift-tools-version: 6.2
// Standalone cross-platform Swift port of anomalyco/opentui (`swift-opentui`).

import PackageDescription

let package = Package(
    name: "OpenTUI",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // Pure portable libraries (all Swift platforms incl. macOS, iOS, Linux, Windows, Android, FreeBSD, WASI)
        .library(name: "OpenTUICore", targets: ["OpenTUICore"]),
        .library(name: "OpenTUIKeymap", targets: ["OpenTUIKeymap"]),
        .library(name: "OpenTUILayout", targets: ["OpenTUILayout"]),
        .library(name: "OpenTUIRenderables", targets: ["OpenTUIRenderables"]),
        .library(name: "OpenTUIView", targets: ["OpenTUIView"]),
        .library(name: "OpenTUITerminal", targets: ["OpenTUITerminal"]),

        // Differential parity runner & interactive showcase demo CLI
        .executable(name: "opentui-parity-runner", targets: ["OpenTUIParityRunner"]),
        .executable(name: "opentui-demo", targets: ["OpenTUIDemo"]),
    ],
    targets: [
        // MARK: - Tier 1: Pure Portable Primitives (Zero OS dependencies)
        .target(
            name: "OpenTUICore",
            dependencies: []
        ),
        .target(
            name: "OpenTUIKeymap",
            dependencies: []
        ),

        // MARK: - Tier 2: Layout, Renderables & Declarative View DSL
        .target(
            name: "OpenTUILayout",
            dependencies: ["OpenTUICore"]
        ),
        .target(
            name: "OpenTUIRenderables",
            dependencies: ["OpenTUICore", "OpenTUILayout", "OpenTUIKeymap"]
        ),
        .target(
            name: "OpenTUIView",
            dependencies: ["OpenTUICore", "OpenTUILayout", "OpenTUIRenderables", "OpenTUIKeymap"]
        ),

        // MARK: - Platform Terminal Backend
        .target(
            name: "OpenTUITerminal",
            dependencies: ["OpenTUICore", "OpenTUIKeymap", "OpenTUIRenderables"]
        ),

        // MARK: - Differential Parity Subject Runner & Interactive Demo CLI
        .executableTarget(
            name: "OpenTUIParityRunner",
            dependencies: ["OpenTUICore", "OpenTUIKeymap", "OpenTUILayout", "OpenTUIRenderables", "OpenTUITerminal"]
        ),
        .executableTarget(
            name: "OpenTUIDemo",
            dependencies: ["OpenTUICore", "OpenTUIKeymap", "OpenTUILayout", "OpenTUIRenderables", "OpenTUITerminal", "OpenTUIView"]
        ),

        // MARK: - Test Suites
        .testTarget(
            name: "OpenTUICoreTests",
            dependencies: ["OpenTUICore", "OpenTUILayout", "OpenTUIRenderables", "OpenTUITerminal", "OpenTUIView"]
        ),
        .testTarget(
            name: "OpenTUIKeymapTests",
            dependencies: ["OpenTUIKeymap"]
        ),
        .testTarget(
            name: "OpenTUIParityTests",
            dependencies: ["OpenTUICore", "OpenTUIKeymap", "OpenTUILayout", "OpenTUIRenderables"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
