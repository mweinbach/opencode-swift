# swift-opentui (`OpenTUI`)

A cross-platform Swift 6.2 port of [`anomalyco/opentui`](https://github.com/anomalyco/opentui) with automated code-level drift auditing and live function-level differential parity testing against upstream TypeScript/Zig sources.

Currently nested at `Packages/OpenTUI` inside `swift-opencode` as a self-contained SwiftPM package ready to be used directly or extracted into its own repository.

## Commands

```bash
# Sync upstream anomalyco/opentui to pinned commit in upstream.lock.json
./Packages/OpenTUI/scripts/sync-upstream.sh

# Run full parity pipeline: scan -> live differential diff & snapshots -> drift & purity audit -> Swift Testing
./Packages/OpenTUI/scripts/parity.sh all

# Individual commands
./Packages/OpenTUI/scripts/parity.sh scan
./Packages/OpenTUI/scripts/parity.sh diff
./Packages/OpenTUI/scripts/parity.sh audit
./Packages/OpenTUI/scripts/parity.sh test
```

See [PARITY.md](PARITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for current parity metrics and architecture details.
