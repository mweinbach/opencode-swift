import path from "node:path"

export type PortTier = "tier1-foundation" | "tier2-engine" | "tier3-surfaces" | "tier4-extensions"

/**
 * A tracked package that lives in its own upstream repository instead of
 * `anomalyco/opencode/packages/<name>`. It is pinned by its own lock file and
 * checked out under `upstream/<dir>` by `scripts/sync-upstream.sh`.
 */
export interface ExternalRepoSpec {
  /** Checkout directory relative to the repository root (gitignored). */
  readonly dir: string
  /** Lock file relative to the repository root. */
  readonly lockFile: string
  /**
   * The opencode package.json whose `dependencies[<npmName>]` decides which
   * version of this repo upstream actually ships. The audit fails when the
   * pinned tag drifts from that version.
   */
  readonly consumer: { readonly upstreamPackage: string; readonly npmName: string }
}

export interface PackageSpec {
  readonly upstreamPackage: string
  readonly swiftTarget: string
  readonly tier: PortTier
  readonly language: "ts" | "rs"
  readonly description: string
  readonly external?: ExternalRepoSpec
}

/** Absolute root of a tracked package checkout (the directory that holds `src/` and `package.json`). */
export function packageRoot(rootDir: string, pkg: PackageSpec): string {
  return pkg.external
    ? path.join(rootDir, pkg.external.dir)
    : path.join(rootDir, "upstream/opencode/packages", pkg.upstreamPackage)
}

export function packageRootByName(rootDir: string, name: string): string {
  const spec = TRACKED_PACKAGES.find((p) => p.upstreamPackage === name)
  return spec ? packageRoot(rootDir, spec) : path.join(rootDir, "upstream/opencode/packages", name)
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
  {
    upstreamPackage: "latex",
    swiftTarget: "OpenCodeTUI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "Built-in TUI LaTeX/math markdown rendering plugin",
  },
  {
    upstreamPackage: "merman",
    swiftTarget: "OpenCodeTUI",
    tier: "tier3-surfaces",
    language: "ts",
    description: "Built-in TUI Mermaid ASCII/Unicode diagram rendering plugin",
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
    upstreamPackage: "plugin-browser",
    swiftTarget: "OpenCodeCore",
    tier: "tier4-extensions",
    language: "ts",
    description: "Chrome DevTools & browser automation built-in core plugin",
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
  {
    // Upstream extracted Code Mode's language (compiler, VM, runtime, stdlib,
    // snapshots, Effect driver) out of packages/codemode/src/language into the
    // standalone `psychoscript` npm package. @opencode/codemode depends on it.
    upstreamPackage: "psychoscript",
    swiftTarget: "OpenCodeCore",
    tier: "tier4-extensions",
    language: "ts",
    description: "Code Mode language: compiler, VM, runtime, stdlib, snapshots (anomalyco/psychoscript)",
    external: {
      dir: "upstream/psychoscript",
      lockFile: "upstream.psychoscript.lock.json",
      consumer: { upstreamPackage: "codemode", npmName: "psychoscript" },
    },
  },
  {
    upstreamPackage: "http-recorder",
    swiftTarget: "OpenCodeRecorder",
    tier: "tier4-extensions",
    language: "ts",
    description: "Deterministic HTTP and WebSocket cassette recorder, replayer, and secret redactor",
  },
  {
    upstreamPackage: "simulation",
    swiftTarget: "OpenCodeSimulation",
    tier: "tier4-extensions",
    language: "ts",
    description: "Deterministic frontend and backend simulation driver, control server, and recorder",
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
  "httpapi-codegen",
  "script",
  "data",
  "effect-drizzle-sqlite",
  "identity",
  "plugins",
]

export const EXEMPT_RUNTIME_DEPS: Readonly<Record<string, string>> = {
  "@opencode/ui": "Static audio .mp3 asset paths only (@opencode/ui/audio/*.mp3, bundled natively in OpenCodeTUI/Resources); web UI components are out of scope",
}

export type TargetPurity = "pure" | "portable" | "platform" | "host"

export const SWIFT_TARGET_PURITY: Record<string, TargetPurity> = {
  OpenCodeUtil: "pure",
  OpenCodeSchema: "pure",
  OpenCodeProtocol: "pure",
  OpenCodeAI: "portable",
  OpenCodeClient: "portable",
  OpenCodeRecorder: "portable",
  OpenCodePlatform: "platform",
  OpenCodeCore: "host",
  OpenCodeServer: "host",
  OpenCodeSDK: "host",
  OpenCodeTUI: "host",
  OpenCodeSimulation: "host",
  OpenCodeGUIPlugins: "host",
  OpenCodeApp: "host",
  OpenCodeAppMain: "host",
  OpenCodeCLIKit: "host",
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
