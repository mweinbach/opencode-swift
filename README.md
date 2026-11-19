<img src="assets/icon.svg" width="64" height="64" alt="">

# swift-opencode

Cross-platform Swift 6.2 port of [`anomalyco/opencode`](https://github.com/anomalyco/opencode) and [`anomalyco/opentui`](https://github.com/anomalyco/opentui) (in `Packages/OpenTUI`), built with strict concurrency, universal Swift platform layering (macOS, iOS/visionOS/tvOS/watchOS, Linux, Windows, Android, FreeBSD, WASI), **Swift Testing**, and an automated **code-level + function-level differential parity harness**.

## Workspace Structure

```text
swift-opencode/
├── Package.swift                 # Multi-target Swift 6.2 package mirroring upstream DAG
├── upstream.lock.json            # Pinned anomalyco/opencode commit
├── PARITY.md                     # Auto-generated OpenCode parity dashboard
├── docs/
│   ├── ARCHITECTURE.md           # Upstream analysis, module DAG & cross-platform matrix
│   └── PORTING_PLAN.md           # Phased porting roadmap & parity gates
├── Sources/
│   ├── OpenCodeUtil/             # Pure Swift stdlib utilities (all Swift platforms)
│   ├── OpenCodeSchema/           # Pure Swift domain types & branded IDs
│   ├── OpenCodeProtocol/         # Pure Swift HTTP API contract descriptors (38 groups)
│   ├── OpenCodePlatform/         # #if os(...) cross-platform OS abstractions
│   ├── OpenCodeAI/               # LLM protocol adapters over HTTPTransport
│   ├── OpenCodeClient/           # Typed HTTP/SSE/WS client
│   ├── OpenCodeCore/             # Event-sourced session runtime, SQLite, tools, MCP
│   ├── OpenCodeServer/           # HTTP/SSE/WS API server
│   ├── OpenCodeSDK/              # Composed Client + Core + Server SDK
│   ├── OpenCodeTUI/              # OpenCode TUI built on Packages/OpenTUI
│   ├── OpenCodeCLI/              # `opencode` executable
│   └── OpenCodeParityRunner/     # NDJSON differential parity runner
├── Packages/OpenTUI/             # Standalone SwiftPM port of anomalyco/opentui + own parity harness
├── Tests/                        # Swift Testing suites (incl. offline oracle snapshot verification)
├── Tools/parity/                 # Upstream symbol scanner, drift/purity auditor, live Bun oracle
├── parity/                       # Upstream manifest, audit report & differential test vectors
└── scripts/
    ├── sync-upstream.sh          # Shallow-clone/sync pinned upstream checkout (gitignored)
    ├── parity.sh                 # Run scan | diff | snapshot | audit | test | all
    └── test.sh                   # Cross-platform Swift Testing runner (incl. macOS CLT support)
```

## Quick Start

```bash
# 1. Sync pinned upstream checkouts (anomalyco/opencode & anomalyco/opentui)
./scripts/parity.sh sync

# 2. Run the full parity pipeline across BOTH swift-opencode and Packages/OpenTUI:
#    scan upstream -> live differential diff & golden snapshots -> drift & purity audit -> Swift Testing
./scripts/parity.sh all

# 3. Run Swift Testing offline (no Bun required)
./scripts/test.sh
./scripts/test.sh Packages/OpenTUI

# 4. Run the bootstrap CLI
swift run opencode debug
```

## Parity Dashboards & Docs

- [PARITY.md](PARITY.md) — Live code-level & function-level parity matrix for `anomalyco/opencode`
- [Packages/OpenTUI/PARITY.md](Packages/OpenTUI/PARITY.md) — Live parity matrix for `anomalyco/opentui`
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Full upstream breakdown & cross-platform Swift blueprint
- [docs/PORTING_PLAN.md](docs/PORTING_PLAN.md) — Phased porting plan and subsystem translation guide
