# swift-opencode Agent Guide

This repository hosts the cross-platform Swift 6.2 port of [`anomalyco/opencode`](https://github.com/anomalyco/opencode) and the standalone nested SwiftPM port of [`anomalyco/opentui`](https://github.com/anomalyco/opentui) under [`Packages/OpenTUI`](Packages/OpenTUI).

## Architecture & Module Dependency Laws

Preserve the strict acyclic dependency direction (matching upstream OpenCode):

- **Pure Tier (`pure`)**: `OpenCodeUtil`, `OpenCodeSchema`, `OpenCodeProtocol`, and `Packages/OpenTUI` targets `OpenTUICore`, `OpenTUIKeymap`, `OpenTUILayout`, `OpenTUIRenderables`, `OpenTUIView`.
  - Must compile on **every platform Swift 6 supports**: macOS, iOS, iPadOS, tvOS, watchOS, visionOS, Linux (glibc/musl), Windows, Android, FreeBSD, and WASI/WebAssembly.
  - **Never** import OS-specific modules (`Darwin`, `Glibc`, `Musl`, `WinSDK`, `CRT`, `Android`, `WASILibc`, `AppKit`, `UIKit`, `SwiftUI`, `Combine`, `ObjectiveC`, `Security`, `CoreFoundation`, `FoundationNetworking`, `Dispatch`).
  - Keep `OpenCodeUtil`, `OpenTUICore`, and `OpenTUIKeymap` pure Swift standard library wherever possible.
- **Portable Tier (`portable`)**: `OpenCodeAI`, `OpenCodeClient`.
  - `OpenCodeClient` may depend on `OpenCodeSchema`, `OpenCodeProtocol`, and `OpenCodePlatform` — **never** `OpenCodeCore` or `OpenCodeServer`.
  - All network I/O must go through `OpenCodePlatform.HTTPTransport`; never import OS networking or C libraries directly.
- **Platform Tier (`platform`)**: `OpenCodePlatform`, `OpenTUITerminal`.
  - Every OS-specific import (`Darwin`, `Glibc`, `Musl`, `WinSDK`, `CRT`, etc.) must be guarded with `#if os(...)` or `#if canImport(...)`.
  - Provide injectable protocols (`EnvironmentProviding`, `HTTPTransport`, `OpenCodeFileSystem`, `ProcessSpawner`, `TerminalBackend`) so higher layers stay testable and portable.
- **Host Tier (`host`)**: `OpenCodeCore`, `OpenCodeServer`, `OpenCodeSDK`, `OpenCodeTUI`, `OpenCodeCLI`.
  - `OpenCodeSDK` composes `OpenCodeClient`, `OpenCodeCore`, and `OpenCodeServer`.
  - `OpenCodeTUI` consumes `Packages/OpenTUI` products (`OpenTUICore`, `OpenTUIKeymap`, `OpenTUILayout`, `OpenTUIRenderables`, `OpenTUITerminal`, `OpenTUIView`).
  - Any OS-specific import must be guarded with `#if os(...)` or `#if canImport(...)`.

## Swift 6 Concurrency & Language Standards

- Target **Swift 6 language mode** (`swiftLanguageModes: [.v6]`) with zero concurrency warnings.
- Prefer immutable `Sendable` value types (`struct`, `enum`), typed throws (`throws(MyError)`), and `actor` / `Synchronization.Mutex` for isolated mutable state.
- **UTF-16 vs Swift `Character` caution**: Where upstream JavaScript/TypeScript depends on UTF-16 code-unit lengths, indices, hashing, or ordering (`checksum`, `sampledChecksum`, `TextBoundary`, `SessionMention`, `Binary`, `truncateMiddle`), operate explicitly on `.utf16` so differential parity holds across ASCII, CJK, and emoji/surrogate pairs.
- **Do not interchange** byte lengths, UTF-16 code units, Unicode scalars, grapheme clusters, and terminal display-cell widths.

## Testing (Swift Testing Only)

- **Always use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`). Do **not** write `XCTest` suites.
- Run tests via `./scripts/test.sh` (for root `swift-opencode`) and `./scripts/test.sh Packages/OpenTUI` (for `OpenTUI`), or `./scripts/parity.sh test` for both.
  - `./scripts/test.sh` passes `--disable-xctest --enable-swift-testing` and automatically wires macOS Command Line Tools' `Testing.framework` search path when full `Xcode.app` is absent.
- **Command Line Tools cross-import rule**: Never import `Foundation` or `FoundationEssentials` in the same `.swift` file that imports `Testing` (macOS CLT omits `_Testing_Foundation.swiftmodule` for the cross-import overlay). Put any fixture/file decoding helpers in a separate file (like `SnapshotLoader.swift`) that does not `import Testing`.

## Code-Level & Function-Level Parity Workflow

Both `swift-opencode` (`upstream.lock.json`) and `Packages/OpenTUI` (`Packages/OpenTUI/upstream.lock.json`) pin exact upstream commits (checked out into gitignored `upstream/` via `./scripts/parity.sh sync`).

When porting any upstream function or type:

1. **Annotate the Swift declaration** with its exact upstream symbol ID and source hash from `parity/upstream-manifest.json`:
   ```swift
   // parity: util/src/encode.ts#checksum [status=implemented hash=55b1d17100d8]
   public func checksum(_ content: String) -> String?
   ```
   Valid statuses: `implemented`, `adapted`, `partial`, `stub`, `excluded`.
2. **Add differential test vectors** in `parity/vectors/*.json` (or `Packages/OpenTUI/parity/vectors/*.json`).
3. **Wire dispatchers** in:
   - `Tools/parity/oracle.ts` (imports the real upstream TypeScript module via Bun)
   - `Sources/OpenCodeParityRunner/main.swift` (or `Packages/OpenTUI/Sources/OpenTUIParityRunner/main.swift`)
   - `Tests/OpenCodeParityTests/ParitySnapshotTests.swift` (or `Packages/OpenTUI/Tests/OpenTUIParityTests/OpenTUIParitySnapshotTests.swift`)
4. **Run full verification** before finishing any porting PR:
   ```bash
   ./scripts/parity.sh all
   ```
   This runs upstream scanning, live differential comparison (updating golden snapshots for Bun-free Swift Testing), code-level drift & cross-platform purity auditing (`--fail-on-drift`, regenerating `PARITY.md`), and Swift Testing across both packages.

## Upstream Sync & Drift Handling

- Run `./scripts/parity.sh sync` to check out the exact commits pinned in both `upstream.lock.json` files.
- To bump upstream to latest HEAD, run `./scripts/parity.sh sync --update` followed by `./scripts/parity.sh scan` and `./scripts/parity.sh audit` to inspect every drifted symbol whose upstream `bodyHash` changed.
- Never edit generated `PARITY.md`, `parity/upstream-manifest.json`, `parity/report.json`, or `Fixtures/oracle-snapshots.json` by hand — regenerate them with `./scripts/parity.sh`.

## Session Core Invariants (When Porting `OpenCodeCore`)

Preserve upstream's core session architecture (`upstream/opencode/AGENTS.md`):
- Keep durable events minimal (irreducible facts) and project read models transactionally.
- Separate durable prompt admission (`session.inbox.enqueued` → `session_inbox`) from model execution (`SessionExecution.wake`).
- Execute one explicit LLM step per runner iteration from reloaded history — do not introduce an in-memory tool loop.
- Keep `SessionRunner`, tool registry, permissions, and filesystem Location-scoped; keep `SessionExecution` process-global and Session-ID based.
- Never block server handlers waiting for async plugin loading.
