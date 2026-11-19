export type PortTier = "tier1-foundation" | "tier2-engine" | "tier3-surfaces" | "tier4-extensions"

export interface PackageSpec {
  readonly upstreamPackage: string
  readonly swiftTarget: string
  readonly tier: PortTier
  readonly language: "ts" | "rs"
  readonly description: string
}

export const TRACKED_PACKAGES: readonly PackageSpec[] = [
  // Tier 1: Pure portable foundation (all Swift platforms incl. iOS, Android, Windows, Linux, FreeBSD, WASI)
  {
    upstreamPackage: "util",
    swiftTarget: "OpenCodeUtil",
    tier: "tier1-foundation",
    language: "ts",
    description: "Pure utility algorithms, encoding, hashing, path normalization, patches, text boundaries",
  },
  {
    upstreamPackage: "schema",
    swiftTarget: "OpenCodeSchema",
    tier: "tier1-foundation",
    language: "ts",
    description: "Domain types, branded IDs, config schemas, durable events, wire models",
  },
  {
    upstreamPackage: "protocol",
    swiftTarget: "OpenCodeProtocol",
    tier: "tier1-foundation",
    language: "ts",
    description: "Typed HTTP API contract groups, error schemas, middleware contracts",
  },

  // Tier 2: Engine, AI protocols, Client, SDK
  {
    upstreamPackage: "ai",
    swiftTarget: "OpenCodeAI",
    tier: "tier2-engine",
    language: "ts",
    description: "LLM provider protocols, streaming decoders, tool loops, cache policy, routing",
  },
  {
    upstreamPackage: "core",
    swiftTarget: "OpenCodeCore",
    tier: "tier2-engine",
    language: "ts",
    description: "Session runner, SQLite event store & projections, tools, permissions, MCP, VCS, config",
  },
  {
    upstreamPackage: "client",
    swiftTarget: "OpenCodeClient",
    tier: "tier2-engine",
    language: "ts",
    description: "Typed HTTP/SSE/WS client and background service discovery",
  },
  {
    upstreamPackage: "sdk",
    swiftTarget: "OpenCodeSDK",
    tier: "tier2-engine",
    language: "ts",
    description: "Composed SDK combining Client, Core, and Server",
  },

  // Tier 3: Server, CLI, TUI & Rendering
  {
    upstreamPackage: "server",
    swiftTarget: "OpenCodeServer",
    tier: "tier3-surfaces",
    language: "ts",
    description: "HTTP/SSE/WS API server, auth, CORS, event feed, pairing, location routing",
  },
  {
    upstreamPackage: "cli",
    swiftTarget: "OpenCodeCLI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "CLI commands, ACP bridge, server lifecycle management, headless runner",
  },
  {
    upstreamPackage: "tui",
    swiftTarget: "OpenCodeTUI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "Cross-platform terminal user interface",
  },
  {
    upstreamPackage: "theme",
    swiftTarget: "OpenCodeTUI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "Semantic TUI theme token resolution and defaults",
  },
  {
    upstreamPackage: "patchmark",
    swiftTarget: "OpenCodeTUI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "Incremental streaming markdown parser",
  },

  // Tier 4: Plugins, Persistent PTY Daemon, Codemode Sandbox
  {
    upstreamPackage: "plugin",
    swiftTarget: "OpenCodeCore",
    tier: "tier4-extensions",
    language: "ts",
    description: "Plugin host contract, RPC hooks, storage, and permissions",
  },
  {
    upstreamPackage: "process-daemon",
    swiftTarget: "OpenCodePlatform",
    tier: "tier4-extensions",
    language: "rs",
    description: "Persistent PTY daemon, VT state, IPC transport (Unix domain socket / Windows named pipe)",
  },
  {
    upstreamPackage: "codemode",
    swiftTarget: "OpenCodeCore",
    tier: "tier4-extensions",
    language: "ts",
    description: "Sandboxed scripting runtime for tool composition",
  },
]

export const OUT_OF_SCOPE_WEB_PACKAGES: readonly string[] = [
  "app",
  "desktop",
  "gui-plugins",
  "ui",
  "session-ui",
  "stories",
  "nav-menus",
  "latex",
  "merman",
  "plugin-browser",
  "http-recorder",
  "httpapi-codegen",
  "simulation",
  "script",
  "data",
  "effect-drizzle-sqlite",
  "identity",
  "plugins",
]

export type TargetPurity = "pure" | "portable" | "platform" | "host"

export const SWIFT_TARGET_PURITY: Record<string, TargetPurity> = {
  OpenCodeUtil: "pure",
  OpenCodeSchema: "pure",
  OpenCodeProtocol: "pure",
  OpenCodeAI: "portable",
  OpenCodeClient: "portable",
  OpenCodePlatform: "platform",
  OpenCodeCore: "host",
  OpenCodeServer: "host",
  OpenCodeSDK: "host",
  OpenCodeTUI: "host",
  OpenCodeCLI: "host",
}

export const FORBIDDEN_PURE_IMPORTS = new Set([
  "Darwin",
  "Glibc",
  "Musl",
  "WinSDK",
  "CRT",
  "Android",
  "WASILibc",
  "AppKit",
  "UIKit",
  "SwiftUI",
  "Combine",
  "ObjectiveC",
  "Security",
  "CoreFoundation",
  "FoundationNetworking",
  "Dispatch",
])

export const OS_SPECIFIC_IMPORTS = new Set([
  "Darwin",
  "Glibc",
  "Musl",
  "WinSDK",
  "CRT",
  "Android",
  "WASILibc",
  "AppKit",
  "UIKit",
  "ObjectiveC",
  "Security",
  "CoreFoundation",
  "FoundationNetworking",
])
