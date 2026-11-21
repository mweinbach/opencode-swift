#!/usr/bin/env bash
set -euo pipefail
# Debug builds run the pure-Swift machine-link crypto slowly; give handshakes room under parallel load.
export OPENCODE_MACHINE_LINK_DEADLINE_MS="${OPENCODE_MACHINE_LINK_DEADLINE_MS:-60000}"

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

if [[ "${CI:-}" == "true" ]] && [[ "$(uname -s)" == "Darwin" ]] && [[ "${TEST_WATCHDOG_SECONDS:-540}" -gt 0 ]]; then
  WATCHDOG_SECS="${TEST_WATCHDOG_SECONDS:-540}"
  (cd "${TARGET_DIR}" && swift test "${EXTRA_FLAGS[@]}" "$@") &
  TEST_PID=$!
  (
    HELPER_ELAPSED=0
    while kill -0 "${TEST_PID}" 2>/dev/null; do
      sleep 5
      HELPER_PID="$(pgrep -f "swiftpm-testing-helper" 2>/dev/null | head -n 1 || true)"
      if [[ -n "${HELPER_PID}" ]]; then
        HELPER_ELAPSED=$((HELPER_ELAPSED + 5))
        if [[ "${HELPER_ELAPSED}" -ge "${WATCHDOG_SECS}" ]]; then
          echo "::error::swiftpm-testing-helper (pid ${HELPER_PID}) exceeded ${WATCHDOG_SECS}s — sampling call stacks before terminating" >&2
          sample "${HELPER_PID}" 2 -file /dev/stdout 2>&1 | head -n 400 >&2 || true
          kill -KILL "${HELPER_PID}" "${TEST_PID}" 2>/dev/null || true
          exit 0
        fi
      fi
    done
  ) &
  WATCHDOG_PID=$!
  set +e
  wait "${TEST_PID}"
  TEST_STATUS=$?
  set -e
  kill "${WATCHDOG_PID}" 2>/dev/null || true
  wait "${WATCHDOG_PID}" 2>/dev/null || true
  exit "${TEST_STATUS}"
fi

(cd "${TARGET_DIR}" && swift test "${EXTRA_FLAGS[@]}" "$@")
