#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENTUI_DIR="${ROOT_DIR}/Packages/OpenTUI"
OPENTUNNEL_DIR="${ROOT_DIR}/Packages/OpenTunnel"
CMD="${1:-all}"
shift || true

require_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required for upstream scanning and live differential oracle checks." >&2
    echo "hint: run './scripts/test.sh' to verify offline golden parity snapshots with Swift Testing without bun." >&2
    exit 1
  fi
}

case "${CMD}" in
  sync)
    "${ROOT_DIR}/scripts/sync-upstream.sh" "$@"
    "${OPENTUI_DIR}/scripts/sync-upstream.sh" "$@"
    ;;
  scan)
    require_bun
    bun "${ROOT_DIR}/Tools/parity/scanner.ts" "$@"
    bun "${OPENTUI_DIR}/Tools/parity/scanner.ts" "$@"
    ;;
  audit)
    require_bun
    bun "${ROOT_DIR}/Tools/parity/audit.ts" "$@"
    bun "${OPENTUI_DIR}/Tools/parity/audit.ts" "$@"
    ;;
  diff)
    require_bun
    bun "${ROOT_DIR}/Tools/parity/diff.ts" "$@"
    bun "${OPENTUI_DIR}/Tools/parity/diff.ts" "$@"
    ;;
  snapshot)
    require_bun
    bun "${ROOT_DIR}/Tools/parity/diff.ts" --write-snapshots "$@"
    bun "${OPENTUI_DIR}/Tools/parity/diff.ts" --write-snapshots "$@"
    ;;
  test)
    "${ROOT_DIR}/scripts/test.sh" "${ROOT_DIR}" "$@"
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUI_DIR}" "$@"
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUNNEL_DIR}" "$@"
    ;;
  check)
    require_bun
    bun test "${ROOT_DIR}/Tools/parity"
    bun "${ROOT_DIR}/Tools/parity/diff.ts" --check-snapshots
    bun "${OPENTUI_DIR}/Tools/parity/diff.ts" --check-snapshots
    bun "${ROOT_DIR}/Tools/parity/audit.ts" --fail-on-drift --strict --no-write
    bun "${OPENTUI_DIR}/Tools/parity/audit.ts" --fail-on-drift --strict --no-write
    "${ROOT_DIR}/scripts/test.sh" "${ROOT_DIR}" -Xswiftc -warnings-as-errors
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUI_DIR}" -Xswiftc -warnings-as-errors
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUNNEL_DIR}" -Xswiftc -warnings-as-errors
    ;;
  all)
    require_bun
    bun test "${ROOT_DIR}/Tools/parity"
    bun "${ROOT_DIR}/Tools/parity/scanner.ts"
    bun "${OPENTUI_DIR}/Tools/parity/scanner.ts"
    bun "${ROOT_DIR}/Tools/parity/diff.ts" --write-snapshots
    bun "${OPENTUI_DIR}/Tools/parity/diff.ts" --write-snapshots
    bun "${ROOT_DIR}/Tools/parity/audit.ts" --fail-on-drift --strict
    bun "${OPENTUI_DIR}/Tools/parity/audit.ts" --fail-on-drift --strict
    "${ROOT_DIR}/scripts/test.sh" "${ROOT_DIR}" -Xswiftc -warnings-as-errors
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUI_DIR}" -Xswiftc -warnings-as-errors
    "${ROOT_DIR}/scripts/test.sh" "${OPENTUNNEL_DIR}" -Xswiftc -warnings-as-errors
    ;;
  *)
    cat <<EOF
Usage: ./scripts/parity.sh <command>

Commands:
  sync       Sync upstream/opencode and upstream/opentui to their pinned commits (--update to bump)
  scan       Extract all upstream symbols + source hashes for OpenCode and OpenTUI
  audit      Check Swift // parity: mappings, upstream drift, and cross-platform purity -> PARITY.md
  diff       Run live differential tests (upstream Bun oracles vs Swift) on parity/vectors/*.json
  snapshot   Run diff and update golden snapshots for Bun-free Swift Testing
  test       Run Swift Testing suites for both swift-opencode and Packages/OpenTUI
  check      Non-mutating CI verification (diff --check-snapshots -> audit --fail-on-drift --strict -> warnings-as-errors Swift Testing)
  all        Run scan -> snapshot -> audit --fail-on-drift --strict -> warnings-as-errors Swift Testing for both packages
EOF
    exit 1
    ;;
esac
