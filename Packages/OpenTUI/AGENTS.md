# swift-opentui Agent Guide

`Packages/OpenTUI` is a standalone, cross-platform Swift 6.2 port of [`anomalyco/opentui`](https://github.com/anomalyco/opentui). It must remain self-contained (zero imports from parent `swift-opencode` targets) so it can be consumed directly or extracted into its own repository.

## Engineering Rules

- **Pure Swift targets** (`OpenTUICore`, `OpenTUIKeymap`, `OpenTUILayout`, `OpenTUIRenderables`, `OpenTUIView`) must never import OS-specific modules (`Darwin`, `Glibc`, `Musl`, `WinSDK`, `CRT`, `AppKit`, `UIKit`, `Dispatch`, etc.).
- **`OpenTUITerminal`** owns all OS terminal I/O behind `#if os(...)` / `#if canImport(...)` guards and keeps `MemoryTerminalBackend` working headless on every Swift platform (including iOS and WASI).
- Preserve bit-exact ABI compatibility with `opentui.h` for `RGBA` (4×`UInt16` channel+meta packing), `TextAttributes` (8-bit base style + 24-bit link ID), and `BorderCharArrays` (11×`UInt32` scalars).
- Never interchange byte counts, UTF-16 units, Unicode scalars, grapheme clusters, and terminal cell widths.
- **Always use Swift Testing** (`import Testing`), never `XCTest`. Keep `Foundation` / `FoundationEssentials` imports out of files that `import Testing` (use `SnapshotLoader.swift` for fixture I/O).

## Parity Commands

```bash
./Packages/OpenTUI/scripts/parity.sh all       # scan -> live diff + snapshots -> drift/purity audit -> Swift Testing
./Packages/OpenTUI/scripts/parity.sh diff      # live Bun upstream TS oracle vs Swift OpenTUIParityRunner
./Packages/OpenTUI/scripts/parity.sh audit     # check // parity: annotations, drift, and purity -> PARITY.md
./Packages/OpenTUI/scripts/parity.sh test      # offline Swift Testing (no Bun required)
```
