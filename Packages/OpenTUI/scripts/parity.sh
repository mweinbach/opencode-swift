#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-all}"
shift || true

require_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required for upstream scanning and live differential oracle checks." >&2
    exit 1
  fi
}

run_swift_testing() {
  local extra_flags=(--disable-xctest --enable-swift-testing)
  if [[ "$(uname -s)" == "Darwin" ]] && command -v xcode-select >/dev/null 2>&1; then
    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    local clt_fw="${dev_dir}/Library/Developer/Frameworks"
    if [[ "${dev_dir}" == *"CommandLineTools"* ]] && [[ -d "${clt_fw}/Testing.framework" ]]; then
      extra_flags+=(
        -Xswiftc "-F${clt_fw}"
        -Xlinker "-F${clt_fw}"
        -Xlinker -rpath -Xlinker "${clt_fw}"
      )
    fi
  fi
  (cd "${PKG_DIR}" && swift test "${extra_flags[@]}" "$@")
}

case "${CMD}" in
  sync)
    "${PKG_DIR}/scripts/sync-upstream.sh" "$@"
    ;;
  scan)
    require_bun
    bun "${PKG_DIR}/Tools/parity/scanner.ts" "$@"
    ;;
  audit)
    require_bun
    bun "${PKG_DIR}/Tools/parity/audit.ts" "$@"
    ;;
  diff)
    require_bun
    bun "${PKG_DIR}/Tools/parity/diff.ts" "$@"
    ;;
  snapshot)
    require_bun
    bun "${PKG_DIR}/Tools/parity/diff.ts" --write-snapshots "$@"
    ;;
  test)
    run_swift_testing "$@"
    ;;
  all)
    require_bun
    bun "${PKG_DIR}/Tools/parity/scanner.ts"
    bun "${PKG_DIR}/Tools/parity/diff.ts" --write-snapshots
    bun "${PKG_DIR}/Tools/parity/audit.ts" --fail-on-drift
    run_swift_testing
    ;;
  *)
    echo "Usage: ./Packages/OpenTUI/scripts/parity.sh <sync|scan|audit|diff|snapshot|test|all>"
    exit 1
    ;;
esac
