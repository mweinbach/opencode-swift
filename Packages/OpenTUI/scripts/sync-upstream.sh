#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${PKG_DIR}/upstream.lock.json"

# When nested inside swift-opencode/Packages/OpenTUI, reuse the workspace's upstream/opentui folder;
# when extracted standalone as swift-opentui, use ./upstream/opentui.
if [[ -d "${PKG_DIR}/../../upstream" ]]; then
  TARGET_DIR="${PKG_DIR}/../../upstream/opentui"
else
  TARGET_DIR="${PKG_DIR}/upstream/opentui"
fi

read_lock() {
  local key="$1"
  if command -v bun >/dev/null 2>&1; then
    bun -e "const d = await Bun.file(process.argv[1]).json(); console.log(d[process.argv[2]] ?? '');" "${LOCK_FILE}" "${key}"
  else
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "${LOCK_FILE}" "${key}"
  fi
}

REPO_URL="$(read_lock repository)"
BRANCH="$(read_lock branch)"
COMMIT="$(read_lock commit)"

UPDATE_LATEST=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_LATEST=1
fi

mkdir -p "$(dirname "${TARGET_DIR}")"

if [[ ! -d "${TARGET_DIR}/.git" ]]; then
  echo "Cloning ${REPO_URL} (branch ${BRANCH}) into ${TARGET_DIR}..."
  git clone --depth 1 --branch "${BRANCH}" --single-branch "${REPO_URL}" "${TARGET_DIR}"
fi

if [[ "${UPDATE_LATEST}" -eq 1 ]]; then
  git -C "${TARGET_DIR}" fetch --depth 1 origin "${BRANCH}"
  git -C "${TARGET_DIR}" checkout -f FETCH_HEAD
  NEW_COMMIT="$(git -C "${TARGET_DIR}" rev-parse HEAD)"
  NEW_DATE="$(git -C "${TARGET_DIR}" log -1 --format='%cI')"
  NEW_SUBJECT="$(git -C "${TARGET_DIR}" log -1 --format='%s')"
  if command -v bun >/dev/null 2>&1; then
    bun -e '
      const [file, commit, commitDate, commitSubject] = process.argv.slice(1);
      const data = await Bun.file(file).json();
      data.commit = commit;
      data.commitDate = commitDate;
      data.commitSubject = commitSubject;
      await Bun.write(file, JSON.stringify(data, null, 2) + "\n");
    ' "${LOCK_FILE}" "${NEW_COMMIT}" "${NEW_DATE}" "${NEW_SUBJECT}"
  fi
  echo "Updated upstream.lock.json to ${NEW_COMMIT} (${NEW_SUBJECT})"
  exit 0
fi

CURRENT="$(git -C "${TARGET_DIR}" rev-parse HEAD)"
if [[ "${CURRENT}" != "${COMMIT}" ]]; then
  git -C "${TARGET_DIR}" fetch --depth 1 origin "${COMMIT}"
  git -C "${TARGET_DIR}" checkout -f "${COMMIT}"
fi

echo "OpenTUI upstream checkout ready at $(git -C "${TARGET_DIR}" rev-parse HEAD)"
