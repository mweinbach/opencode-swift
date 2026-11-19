# swift-opencode Architecture & Cross-Platform Blueprint

This document maps the real architecture of `anomalyco/opencode` (pinned at `3aaac7731360`, branch `dev`) and `anomalyco/opentui` (pinned at `79eb7fccd171`, branch `main`) onto a Swift 6.2 strict-concurrency, universal cross-platform package graph.

---

## 1. Upstream Inventory (`anomalyco/opencode`)

Upstream OpenCode is a monorepo built on **Bun/Node + TypeScript 6/7 + Effect-TS 4 + Drizzle SQLite + Rust (`process-daemon`) + OpenTUI**. The non-GUI core/CLI/TUI/AI/protocol/daemon stack comprises **15 packages, 1,708 source files, ~294.3k LOC, 9,404 exported symbols, and 2,443 exported functions**:

| Upstream Package | Files | LOC | Symbols | Functions | Swift Target | Tier |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| `packages/util` | 47 | 5,032 | 200 | 112 | `OpenCodeUtil` | `tier1-foundation` |
| `packages/schema` | 108 | 7,315 | 699 | 23 | `OpenCodeSchema` | `tier1-foundation` |
| `packages/protocol` | 44 | 5,160 | 215 | 29 | `OpenCodeProtocol` | `tier1-foundation` |
| `packages/ai` | 278 | 36,800 | 1,802 | 350 | `OpenCodeAI` | `tier2-engine` |
| `packages/core` | 497 | 84,931 | 1,975 | 523 | `OpenCodeCore` | `tier2-engine` |
| `packages/client` | 35 | 17,753 | 1,597 | 54 | `OpenCodeClient` | `tier2-engine` |
| `packages/sdk` | 15 | 680 | 45 | 16 | `OpenCodeSDK` | `tier2-engine` |
| `packages/server` | 63 | 5,303 | 114 | 43 | `OpenCodeServer` | `tier3-surfaces` |
| `packages/cli` | 116 | 13,210 | 277 | 124 | `OpenCodeCLI` | `tier3-surfaces` |
| `packages/tui` | 301 | 66,822 | 1,013 | 739 | `OpenCodeTUI` | `tier3-surfaces` |
| `packages/theme` | 11 | 2,037 | 75 | 38 | `OpenCodeTUI` | `tier3-surfaces` |
| `packages/patchmark` | 8 | 4,033 | 46 | 25 | `OpenCodeTUI` | `tier3-surfaces` |
| `packages/plugin` | 85 | 10,955 | 470 | 64 | `OpenCodeCore` | `tier4-extensions` |
| `packages/process-daemon` (Rust) | 26 | 12,484 | 356 | 182 | `OpenCodePlatform` | `tier4-extensions` |
| `packages/codemode` | 74 | 21,815 | 520 | 121 | `OpenCodeCore` | `tier4-extensions` |

Out of scope for the native Swift port: web/SolidJS/Electron packages (`app`, `desktop`, `gui-plugins`, `ui`, `session-ui`, `stories`, `nav-menus`, `latex`, `merman`, `plugin-browser`, `http-recorder`, `httpapi-codegen`, `simulation`, `script`).

---

## 2. Swift Module Dependency Graph

We preserve upstream's strict acyclic dependency law (`AGENTS.md`):
- Pure foundation targets (`OpenCodeUtil`, `OpenCodeSchema`, `OpenCodeProtocol`) have **zero OS or runtime dependencies**.
- `OpenCodeClient` depends only on `OpenCodeSchema`, `OpenCodeProtocol`, and `OpenCodePlatform` (never `OpenCodeCore` or `OpenCodeServer`).
- `OpenCodeSDK` composes `OpenCodeClient`, `OpenCodeCore`, and `OpenCodeServer`.
- `OpenCodeTUI` links directly against the standalone Swift OpenTUI package (`Packages/OpenTUI`).

```
OpenCodeUtil (Pure Swift stdlib)
   ├──▶ OpenCodeSchema (Pure Swift + Synchronization)
   │       ├──▶ OpenCodeProtocol (Pure Swift)
   │       │       └──▶ OpenCodeClient ◀── OpenCodePlatform
   │       ├──▶ OpenCodeAI ◀── OpenCodePlatform
   │       └──▶ OpenCodeCore ◀── OpenCodeAI, OpenCodePlatform
   │               └──▶ OpenCodeServer ◀── OpenCodeProtocol, OpenCodePlatform
   │                       └──▶ OpenCodeSDK ◀── OpenCodeClient, OpenCodeCore
   └──▶ OpenCodePlatform (#if os(...) OS boundary)

Packages/OpenTUI (Standalone SwiftPM Package)
   OpenTUICore ──▶ OpenTUILayout ──▶ OpenTUIRenderables ──▶ OpenTUIView
   OpenTUIKeymap ──────────────────▶ OpenTUIRenderables
   OpenTUITerminal ◀── OpenTUICore, OpenTUIKeymap
         │
         ▼
   OpenCodeTUI ──▶ OpenCodeCLI (`opencode` executable)
```

---

## 3. Universal Swift Cross-Platform Matrix

Every target has an explicit **Purity Tier** enforced automatically by `./scripts/parity.sh audit`:

| Target | Purity | macOS | iOS / visionOS / tvOS / watchOS | Linux (glibc/musl) | Windows | Android | FreeBSD | WASI / Wasm |
| --- | --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `OpenCodeUtil` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenCodeSchema` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenCodeProtocol` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenTUICore` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenTUIKeymap` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenTUILayout` / `Renderables` / `View` | `pure` | Full | Full | Full | Full | Full | Full | Full |
| `OpenCodeClient` | `portable` | Full | Full | Full | Full | Full | Full | Via custom `HTTPTransport` |
| `OpenCodeAI` | `portable` | Full | Full | Full | Full | Full | Full | Via custom `HTTPTransport` |
| `OpenCodePlatform` | `platform` | Full | Subset (no subprocess/PTY) | Full | Full (ConPTY + Named Pipes) | Full | Full | Virtual/tmp fallback |
| `OpenCodeCore` | `host` | Full | Embeddable (remote/in-mem tools) | Full | Full | Full | Full | Embeddable subset |
| `OpenCodeServer` | `host` | Full | Loopback/embed | Full | Full | Full | Full | N/A |
| `OpenCodeTUI` / `OpenCodeCLI` | `host` | Full | Headless / `MemoryTerminalBackend` | Full | Full (VT Console) | Full | Full | Headless only |

### Purity Rules Enforced by CI
1. **`pure` targets** (`OpenCodeUtil`, `OpenCodeSchema`, `OpenCodeProtocol`, `OpenTUICore`, `OpenTUIKeymap`, `OpenTUILayout`, `OpenTUIRenderables`, `OpenTUIView`): forbidden from importing `Darwin`, `Glibc`, `Musl`, `WinSDK`, `CRT`, `Android`, `WASILibc`, `AppKit`, `UIKit`, `SwiftUI`, `Combine`, `ObjectiveC`, `Security`, `CoreFoundation`, `FoundationNetworking`, or `Dispatch`.
2. **`portable` targets** (`OpenCodeAI`, `OpenCodeClient`): must talk to the network exclusively through `OpenCodePlatform.HTTPTransport` (never import OS C-libraries or `FoundationNetworking` directly).
3. **`platform` & `host` targets**: every OS-specific import must be enclosed in `#if os(...)` or `#if canImport(...)`.

---

## 4. Key Paradigm Translations (TypeScript/Effect/Zig/Rust → Swift 6)

| Upstream Pattern | Swift 6 Equivalent |
| --- | --- |
| Effect-TS `Effect<A, E, R>` & `Layer` | Swift `async throws(E)` + structured concurrency (`TaskGroup`, `Actor`) + protocol dependency injection (`Sendable` service containers) |
| Effect `Schema` & branded types | `Codable`, `Sendable`, `RawRepresentable` structs (`SessionID`, `ProjectID`, `WorkspaceID`) with validated initializers & typed errors |
| Drizzle SQLite (23 tables + durable event log & projections) | Embedded SQLite C library (`CSQLite` / `sqlite3` amalgamation compiled into SwiftPM for Linux/Windows/Android/Apple consistency) with SQL migration parity from `packages/core/src/database/schema.gen.ts` |
| Effect `HttpApi` (38 route groups) | Declarative `OpenCodeProtocol` endpoint descriptors + `OpenCodeServer` router (SwiftNIO / Hummingbird) + typed `OpenCodeClient` |
| JS UTF-16 `.length` / `.charCodeAt` / `<` | Explicit `.utf16` operations wherever wire/hash/offset parity depends on UTF-16 code units (`checksum`, `TextBoundary`, `SessionMention`, `Binary`) |
| `crypto.createHash` / `crypto.randomUUID` | Pure-Swift FIPS 180-4 SHA-1/SHA-256 (`OpenCodeUtil.Hash`) and Swift stdlib `SystemRandomNumberGenerator` (backed by OS CSPRNG on all Swift targets including WASI) |
| `@opentui/native` (Zig cell buffer, grapheme pool, rope, diff renderer, Yoga) | Pure Swift `OpenTUICore` + `OpenTUILayout` (`CellBuffer`, grapheme width tables, rope edit buffer, ANSI diff encoder, flexbox layout) — zero Zig toolchain required, with exact `opentui.h` ABI layout for `RGBA` & `TextAttributes` |
| `@opentui/solid` / `@opentui/react` | `OpenTUIView` Swift `@resultBuilder` declarative DSL |
| `packages/process-daemon` (Rust persistent PTY + Ghostty VT) | `OpenCodePlatform` PTY abstraction (`posix_openpt`/`forkpty` on POSIX, `CreatePseudoConsole` ConPTY on Windows) + UDS / Windows Named Pipe IPC |
| JS/TS Plugins & Codemode (`acorn`) | Out-of-process JSON-RPC / MCP plugin bridge (preserving existing OpenCode plugin ecosystem) + optional Swift native plugin protocol |

---

## 5. Dual-Level Parity Harness

Both `swift-opencode` and `Packages/OpenTUI` ship identical, automated **code-level + function-level parity harnesses**:

1. **Code-Level Inventory & Drift Detection (`scanner.ts` + `audit.ts`)**:
   - Scans upstream `.ts`/`.tsx`/`.rs`/`.zig` files, extracting every exported symbol and a 12-char SHA-256 `bodyHash` of its normalized implementation (`parity/upstream-manifest.json`).
   - Parses `// parity: <upstream-id> [status=implemented hash=<bodyHash>]` markers in Swift sources.
   - Fails CI on **dangling references**, **cross-platform purity violations**, or **upstream code drift** (`--fail-on-drift`) when `upstream.lock.json` is bumped.
   - Auto-generates `PARITY.md` and `parity/report.json`.
2. **Function-Level Differential Oracle (`oracle.ts` + `diff.ts` + `*ParityRunner`)**:
   - Feeds identical NDJSON test vectors (`parity/vectors/*.json`) to **both** the real upstream TypeScript code (via Bun) and our compiled Swift binary (`opencode-parity-runner` / `opentui-parity-runner`), comparing outputs structurally.
   - Records verified upstream outputs into `Fixtures/oracle-snapshots.json`, which **Swift Testing** (`ParitySnapshotTests` / `OpenTUIParitySnapshotTests`) replays natively inside `swift test` with **zero Bun dependency** on Linux, Windows, macOS, Android, iOS, and WASI.
