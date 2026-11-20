#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-${ROOT_DIR}}"
shift || true

EXTRA_FLAGS=(--disable-xctest --enable-swift-testing)

# Avoid Swift cooperative-pool starvation on 3-4 vCPU CI runners when running >1,100 tests.
if [[ "${CI:-}" == "true" ]]; then
  EXTRA_FLAGS+=(--no-parallel)
fi

# On macOS with Command Line Tools (without full Xcode.app), Testing.framework lives under
# CommandLineTools/Library/Developer/Frameworks and is not added to SwiftPM's default search paths.
if [[ "$(uname -s)" == "Darwin" ]] && command -v xcode-select >/dev/null 2>&1; then
  DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  CLT_FW="${DEV_DIR}/Library/Developer/Frameworks"
  if [[ "${DEV_DIR}" == *"CommandLineTools"* ]] && [[ -d "${CLT_FW}/Testing.framework" ]]; then
    EXTRA_FLAGS+=(
      -Xswiftc "-F${CLT_FW}"
      -Xlinker "-F${CLT_FW}"
      -Xlinker -rpath -Xlinker "${CLT_FW}"
    )
  fi
fi

(cd "${TARGET_DIR}" && swift test "${EXTRA_FLAGS[@]}" "$@")
