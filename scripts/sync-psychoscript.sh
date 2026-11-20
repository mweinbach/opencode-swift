#!/usr/bin/env bash
# Sync the external `psychoscript` upstream (Code Mode's language, extracted from
# anomalyco/opencode packages/codemode/src/language) to the commit pinned in
# upstream.psychoscript.lock.json.
#
#   --update  re-pin to the tag matching the version that
#             upstream/opencode/packages/codemode/package.json depends on
#             (NOT psychoscript HEAD), so parity tracks what opencode ships.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/upstream.psychoscript.lock.json"
TARGET_DIR="${ROOT_DIR}/upstream/psychoscript"
CONSUMER_PKG="${ROOT_DIR}/upstream/opencode/packages/codemode/package.json"

json_get() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); 
for k in sys.argv[2].split("."): d=(d or {}).get(k)
print(d or "")' "$1" "$2"
}

REPO_URL="$(json_get "${LOCK_FILE}" repository)"
COMMIT="$(json_get "${LOCK_FILE}" commit)"

mkdir -p "$(dirname "${TARGET_DIR}")"
if [[ ! -d "${TARGET_DIR}/.git" ]]; then
  echo "Cloning ${REPO_URL} into ${TARGET_DIR}..."
  git clone --quiet --filter=blob:none "${REPO_URL}" "${TARGET_DIR}"
fi

if [[ "${1:-}" == "--update" ]]; then
  WANTED="$(json_get "${CONSUMER_PKG}" dependencies.psychoscript)"
  WANTED="${WANTED#[~^=v]}"
  if [[ -z "${WANTED}" ]]; then
    echo "error: ${CONSUMER_PKG} no longer depends on psychoscript; re-evaluate tracking in Tools/parity/config.ts" >&2
    exit 1
  fi
  TAG="v${WANTED}"
  git -C "${TARGET_DIR}" fetch --quiet --tags origin
  git -C "${TARGET_DIR}" checkout --quiet -f "refs/tags/${TAG}"
  NEW_COMMIT="$(git -C "${TARGET_DIR}" rev-parse HEAD)"
  NEW_DATE="$(git -C "${TARGET_DIR}" log -1 --format='%cI')"
  NEW_SUBJECT="$(git -C "${TARGET_DIR}" log -1 --format='%s')"
  python3 - "${LOCK_FILE}" "${WANTED}" "${TAG}" "${NEW_COMMIT}" "${NEW_DATE}" "${NEW_SUBJECT}" <<'EOF'
import json, sys
path, version, tag, commit, date, subject = sys.argv[1:]
d = json.load(open(path))
d.update(version=version, tag=tag, commit=commit, commitDate=date, commitSubject=subject)
open(path, "w").write(json.dumps(d, indent=2) + "\n")
EOF
  echo "Updated upstream.psychoscript.lock.json to ${TAG} (${NEW_COMMIT})"
  exit 0
fi

if [[ "$(git -C "${TARGET_DIR}" rev-parse HEAD)" != "${COMMIT}" ]]; then
  echo "Syncing psychoscript checkout to pinned commit ${COMMIT}..."
  git -C "${TARGET_DIR}" fetch --quiet origin "${COMMIT}" || git -C "${TARGET_DIR}" fetch --quiet --tags origin
  git -C "${TARGET_DIR}" checkout --quiet -f "${COMMIT}"
fi
echo "psychoscript checkout ready at $(git -C "${TARGET_DIR}" rev-parse HEAD)"
