# swift-opentui Architecture

`Packages/OpenTUI` is a standalone, cross-platform Swift 6.2 port of [`anomalyco/opentui`](https://github.com/anomalyco/opentui) (pinned at `79eb7fccd171`, `main`).

## Upstream Scope (292 files, ~169.4k LOC)
- **`packages/core`** (125 TS files, 66.6k LOC): ABI-packed `RGBA`, `TextAttributes`, `Border`, `ANSI`, input parsers (VT/Kitty/SGR mouse), geometry, viewport culling, renderables (`Box`, `Text`, `Input`, `Textarea`, `ScrollBox`, `Diff`, `Markdown`, `Code`, `Select`, `Table`, `Image`), `TestRenderer`.
- **`packages/keymap`** (66 TS files, 13.8k LOC): Keystroke normalization, match IDs, chord sequences, `when`-conditions, scope layers, command dispatch.
- **`packages/native`** (80 Zig files, 78.1k LOC): Native cell buffer, grapheme pool, rope/edit buffer, text buffer, ANSI diff renderer, Yoga layout bridge, Ghostty VT.
- **`packages/qrcode`** (8 TS files, 8.9k LOC): Terminal QR code renderer.
- **`packages/ssh`** (13 TS files, 2.0k LOC): Remote SSH terminal bridge.

## Pure-Swift Strategy (Zero Zig/FFI Requirement)
Rather than requiring Zig cross-compilation toolchains for every Swift target (macOS, iOS, Linux glibc/musl, Windows, Android, FreeBSD, WASI), `swift-opentui` implements the native rendering primitives directly in **pure Swift 6** while keeping **bit-exact ABI compatibility** with `opentui.h` (`RGBA` 4×`UInt16` lane+meta packing, `TextAttributes` 8-bit style + 24-bit link IDs, `BorderCharArrays` 11×`UInt32` scalars).

## Module Layout
- **`OpenTUICore`** (`pure`): `RGBA`, `TextAttributes`, `Border`, `ANSI`, `RenderGeometry`, `Viewport`, `Validation`, `CellBuffer` (zero OS imports — compiles on every Swift platform including WASI & iOS).
- **`OpenTUIKeymap`** (`pure`): Key normalization, match IDs, key sequences, canonical formatting.
- **`OpenTUILayout`** (`pure`): Flexbox/Yoga-compatible layout engine.
- **`OpenTUIRenderables`** (`pure`): Renderable node tree (`Box`, `Text`, `Input`, `ScrollBox`, `Diff`, `Markdown`, ...).
- **`OpenTUIView`** (`pure`): Swift `@resultBuilder` declarative TUI DSL (replacing `@opentui/solid` & `@opentui/react`).
- **`OpenTUITerminal`** (`platform`): Cross-platform terminal I/O (`termios` on POSIX, VT Console on Windows, headless `MemoryTerminalBackend` everywhere).
