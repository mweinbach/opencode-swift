export type OpenTUITier = "tier1-primitives" | "tier2-engine" | "tier3-components" | "tier4-extensions"

export interface OpenTUIPackageSpec {
  readonly upstreamPackage: string
  readonly swiftTarget: string
  readonly tier: OpenTUITier
  readonly language: "ts" | "zig"
  readonly description: string
}

export const TRACKED_OPENTUI_PACKAGES: readonly OpenTUIPackageSpec[] = [
  {
    upstreamPackage: "core",
    swiftTarget: "OpenTUICore",
    tier: "tier1-primitives",
    language: "ts",
    description: "RGBA colors, text attributes, borders, ANSI escapes, input parsers, geometry, viewport, renderables, renderer",
  },
  {
    upstreamPackage: "keymap",
    swiftTarget: "OpenTUIKeymap",
    tier: "tier1-primitives",
    language: "ts",
    description: "Key normalization, key match IDs, chord sequences, when-conditions, scopes, command dispatch",
  },
  {
    upstreamPackage: "native",
    swiftTarget: "OpenTUICore",
    tier: "tier2-engine",
    language: "zig",
    description: "Zig native cell buffer, grapheme pool, rope/edit buffer, text buffer, ANSI diff renderer, Yoga layout bridge, Ghostty VT",
  },
  {
    upstreamPackage: "qrcode",
    swiftTarget: "OpenTUIRenderables",
    tier: "tier4-extensions",
    language: "ts",
    description: "Terminal Unicode block QR code generator & renderable",
  },
  {
    upstreamPackage: "ssh",
    swiftTarget: "OpenTUITerminal",
    tier: "tier4-extensions",
    language: "ts",
    description: "SSH remote terminal bridge and session transport",
  },
]

export const OUT_OF_SCOPE_OPENTUI_PACKAGES: readonly string[] = [
  "solid",
  "react",
  "rust",
  "three",
  "web",
  "examples",
]

export const EXEMPT_OPENTUI_RUNTIME_DEPS: Readonly<Record<string, string>> = {
  "@opentui/react": "Optional React reconciler peer adapter; Swift uses native OpenTUIView DSL",
  "@opentui/solid": "Optional SolidJS reconciler peer adapter; Swift uses native OpenTUIView DSL",
}

export type TargetPurity = "pure" | "platform" | "host"

export const SWIFT_OPENTUI_TARGET_PURITY: Record<string, TargetPurity> = {
  OpenTUICore: "pure",
  OpenTUIKeymap: "pure",
  OpenTUILayout: "pure",
  OpenTUIRenderables: "pure",
  OpenTUIView: "pure",
  OpenTUITerminal: "platform",
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
