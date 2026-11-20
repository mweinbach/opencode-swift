#!/usr/bin/env bash
# Installs third-party npm packages that upstream depends on and that the differential oracle
# (Tools/parity/oracle.ts) runs for real, at exactly the version pinned in upstream/opencode/bun.lock.
# Installed into the gitignored Tools/parity/.deps so upstream/ stays a pristine checkout.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${ROOT_DIR}/upstream/opencode/bun.lock"
DEPS="${ROOT_DIR}/Tools/parity/.deps"
command -v bun >/dev/null 2>&1 || { echo "warning: bun not found; skipping oracle deps" >&2; exit 0; }
[[ -f "${LOCK}" ]] || { echo "warning: ${LOCK} missing; run sync first" >&2; exit 0; }
pkgs=()
for name in jsonc-parser; do
  ver="$(grep -o "\"${name}@[0-9][^\"]*\"" "${LOCK}" | head -1 | tr -d '"' | sed "s/^${name}@//")"
  [[ -n "${ver}" ]] || { echo "error: ${name} not pinned in ${LOCK}" >&2; exit 1; }
  pkgs+=("${name}@${ver}")
done
mkdir -p "${DEPS}"
[[ -f "${DEPS}/package.json" ]] || echo '{ "private": true }' > "${DEPS}/package.json"
(cd "${DEPS}" && bun add --exact --silent "${pkgs[@]}")
echo "oracle deps ready: ${pkgs[*]}"
