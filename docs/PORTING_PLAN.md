# Porting Roadmap & Milestones

This plan sequences the port of `anomalyco/opencode` and `anomalyco/opentui` into incremental phases, where every phase must clear **100% differential parity**, **zero drift**, **zero purity violations**, and **passing Swift Testing suites across macOS, Linux, and Windows**.

---

## Phase 0: Repository, Cross-Platform Architecture & Parity Harness (Complete)
- Multi-target Swift 6.2 `Package.swift` mirroring upstream's acyclic module DAG.
- Standalone nested SwiftPM package `Packages/OpenTUI` wired into `OpenCodeTUI`.
- Code-level scanner + drift auditor + cross-platform purity checker (`Tools/parity/{scanner,audit}.ts`).
- Live differential oracle harness (`Tools/parity/{oracle,diff}.ts` + `OpenCodeParityRunner` + `OpenTUIParityRunner`).
- Offline golden-snapshot Swift Testing suites (`OpenCodeParityTests`, `OpenTUIParityTests`).
- Initial ported slices:
  - `swift-opencode`: 40 oracle-verified functions (235 vectors) across `OpenCodeUtil` & `OpenCodeSchema` + `OpenCodePlatform` capabilities & XDG paths.
  - `Packages/OpenTUI`: 32 oracle-verified functions (133 vectors) across `OpenTUICore` (ABI-packed `RGBA`, `TextAttributes`, `Border`, `ANSI`, `RenderGeometry`, `Viewport`, `Validation`, `CellBuffer`) & `OpenTUIKeymap`.

## Phase 1: Complete Tier 1 Foundation (`OpenCodeUtil`, `OpenCodeSchema`, `OpenCodeProtocol`, `OpenTUICore`, `OpenTUIKeymap`)
- **OpenCodeUtil**:
  - `patch.ts` (`Patch.parse`, `Patch.derive`, unified/apply-patch hunk engine — pure algorithm, high-value differential suite!)
  - `glob.ts` (pure Swift glob matcher & filesystem scanner via `OpenCodePlatform`)
  - `retry.ts`, `abort.ts`, `activity-calendar.ts`, `artifact.ts`, `execute-output.ts`, `session-turn.ts`, `record.ts`, `qr.ts`
- **OpenCodeSchema**:
  - All domain wire models (`session.ts`, `session-message.ts`, `session-event.ts`, `session-inbox.ts`, `session-error.ts`, `permission.ts`, `config/*`, `agent.ts`, `tool.ts`, `model.ts`, `provider.ts`, `mcp.ts`, `pty.ts`, `worktree.ts`, `vcs.ts`, `event-manifest.ts`).
  - JSON round-trip differential vectors verifying exact wire compatibility with upstream Effect Schema codecs.
- **OpenCodeProtocol**:
  - All 38 route groups (`packages/protocol/src/groups/*`), error envelopes, and OpenAPI identifier parity checks (including experimental route validation).
- **OpenTUI Tier 1**:
  - Input parser (`parse.keypress.ts`, `kitty-keys.ts`, `parse.mouse.ts`, `paste.ts`, verified against upstream `stdin-parser.conformance.json`!).
  - Full `OpenTUIKeymap` sequence compiler, `when`-condition evaluator (`conditions.ts`), scope layer stack, and dispatcher.
  - Link detection (`detect-links.ts`), styled text spans (`styled-text.ts`), scroll acceleration (`scroll-acceleration.ts`), terminal capability parser.

## Phase 2: Cross-Platform Storage, Networking & AI Protocol Engine (`OpenCodePlatform`, `OpenCodeAI`, `OpenCodeClient`)
- **OpenCodePlatform**:
  - Native `HTTPTransport` implementations: `URLSession` (Apple), `AsyncHTTPClient` / `URLSession` (Linux/Windows/Android), pluggable transport hook (WASI).
  - Native `OpenCodeFileSystem`, atomic writes, cross-platform file locking (`flock` / `LockFileEx`), and `ProcessSpawner` (`posix_spawn` / `CreateProcessW`).
  - Embedded C SQLite3 wrapper (`CSQLite`) with WAL mode, migrations from `packages/core/src/database/schema.gen.ts`, and parameterized query safety.
- **OpenCodeAI**:
  - SSE & NDJSON streaming decoders + AWS EventStream codec (`bedrock-event-stream.ts`).
  - Priority provider protocols: Anthropic Messages, OpenAI Responses & Chat Completions, Google Gemini, OpenAI-compatible, Amazon Bedrock Converse.
  - Tool loop, retry/backoff, cache policy, and usage accounting.
- **OpenCodeClient**:
  - Full typed client covering all 38 protocol groups, SSE event feed streaming, and background service discovery/probing.

## Phase 3: Durable Session Core & Tools (`OpenCodeCore`)
- **Event-Sourced Session Store**:
  - Implement upstream's exact durable event log (`event`, `event_sequence`), `session_inbox` admission/delivery transaction semantics, `SessionRunCoordinator`, write-ahead execution claim & restart recovery, and step-by-step `SessionRunner` (reloading history per step, never an in-memory tool loop).
- **Core Tools (`packages/core/src/tool/plugin/*`)**:
  - `read`, `write`, `edit`, `patch`, `glob`, `grep` (native Swift / ripgrep subprocess), `shell`, `webfetch`, `websearch`, `todo`, `question`, `subagent`, `skill`, `artifact`, `mcp-resource`.
- **Subsystems**:
  - Hierarchical config loader (`packages/core/src/config/*`, JSONC, feature flags, managed policy).
  - Permission rule engine & persisted approvals.
  - MCP client/server (stdio & streamable HTTP transports).
  - Git / VCS / Snapshot / Worktree management.

## Phase 4: HTTP/SSE/WS Server, Persistent PTY, TUI & CLI (`OpenCodeServer`, `OpenCodeSDK`, `OpenCodeTUI`, `OpenCodeCLI`)
- **OpenCodeServer**:
  - Cross-platform HTTP/SSE/WS server (SwiftNIO / Hummingbird) implementing all 38 protocol handler groups, auth/pairing, CORS, range requests, and location routing.
- **OpenTUI Engine (`Packages/OpenTUI`)**:
  - Pure Swift double-buffered diff renderer, Unicode grapheme width & East Asian width tables, Rope-backed `EditBuffer`/`EditorView`, Flexbox layout engine, `Markdown` (verified against upstream `markdown.conformance.json`), `Diff` (verified against `diff.conformance.json`), `ScrollBox`, `Input`, `Textarea`, `Select`, `TabSelect`, plus POSIX `termios` and Windows VT console backends.
- **OpenCodeTUI & OpenCodeCLI**:
  - Semantic themes (`packages/theme`), streaming markdown (`packages/patchmark`), full TUI routes & prompt composer.
  - CLI commands (`serve`, `run`, `acp`, `session`, `service`, `auth`, `mcp`, `plugin`, `models`, `stats`, `debug`).
  - Persistent PTY daemon/IPC (`OpenCodePlatform`: POSIX PTY + UDS, Windows ConPTY + Named Pipes).
- **Extensions**:
  - Out-of-process JSON-RPC plugin host (compatible with existing OpenCode plugins) & optional sandboxed scripting bridge.
