#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/upstream.lock.json"
TARGET_DIR="${ROOT_DIR}/upstream/opencode"

if [[ ! -f "${LOCK_FILE}" ]]; then
  echo "error: missing ${LOCK_FILE}" >&2
  exit 1
fi

read_lock() {
  local key="$1"
  if command -v bun >/dev/null 2>&1; then
    bun -e "const d = await Bun.file(process.argv[1]).json(); console.log(d[process.argv[2]] ?? '');" "${LOCK_FILE}" "${key}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "${LOCK_FILE}" "${key}"
  else
    echo "error: requires bun or python3 to read upstream.lock.json" >&2
    exit 1
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
  echo "Fetching latest ${BRANCH} from upstream..."
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
  "${ROOT_DIR}/scripts/sync-psychoscript.sh" --update
  "${ROOT_DIR}/scripts/sync-oracle-deps.sh"
  exit 0
fi

CURRENT="$(git -C "${TARGET_DIR}" rev-parse HEAD)"
if [[ "${CURRENT}" != "${COMMIT}" ]]; then
  echo "Syncing upstream checkout to pinned commit ${COMMIT}..."
  git -C "${TARGET_DIR}" fetch --depth 1 origin "${COMMIT}"
  git -C "${TARGET_DIR}" checkout -f "${COMMIT}"
fi

echo "Upstream checkout ready at $(git -C "${TARGET_DIR}" rev-parse HEAD)"
"${ROOT_DIR}/scripts/sync-psychoscript.sh"
"${ROOT_DIR}/scripts/sync-oracle-deps.sh"
