#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIRECTORY="$(mktemp -d "${TEMP_ROOT%/}/knock-knock-ios-archive-smoke.XXXXXX")"

cleanup() {
  if [[ -d "${TEMP_DIRECTORY}" \
    && "${TEMP_DIRECTORY}" == "${TEMP_ROOT%/}/knock-knock-ios-archive-smoke."* ]]; then
    find "${TEMP_DIRECTORY}" -depth -delete
  fi
}
trap cleanup EXIT

fail() {
  printf 'ios archive security smoke failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "${TEMP_DIRECTORY}/bin"
cat > "${TEMP_DIRECTORY}/bin/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
cat > "${TEMP_DIRECTORY}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "${KNOCK_ARCHIVE_SMOKE_ARGUMENTS_LOG}"
if [[ "${1:-}" == "archive" ]]; then
  key_path=""
  info_plist=""
  for argument in "$@"; do
    case "${argument}" in
      KNOCK_MODEL_PUBLIC_KEY_PATH=*) key_path="${argument#*=}" ;;
      INFOPLIST_FILE=*) info_plist="${argument#*=}" ;;
    esac
  done
  [[ -n "${key_path}" && -f "${key_path}" ]] || exit 41
  [[ -n "${info_plist}" && -f "${info_plist}" ]] || exit 42
  CONFIGURATION=Release \
    KNOCK_MODEL_PUBLIC_KEY_PATH="${key_path}" \
    INFOPLIST_FILE="${info_plist}" \
    "${KNOCK_ARCHIVE_SMOKE_VALIDATOR}"
fi
SH
chmod 700 "${TEMP_DIRECTORY}/bin/xcodegen" "${TEMP_DIRECTORY}/bin/xcodebuild"

run_archive() {
  env \
    PATH="${TEMP_DIRECTORY}/bin:${PATH}" \
    IOS_BUILD_NUMBER=999 \
    IOS_ARCHIVE_PATH="${TEMP_DIRECTORY}/archive/KnockKnock.xcarchive" \
    IOS_EXPORT_PATH="${TEMP_DIRECTORY}/export" \
    KNOCK_ARCHIVE_SMOKE_ARGUMENTS_LOG="${TEMP_DIRECTORY}/xcodebuild-arguments.log" \
    KNOCK_ARCHIVE_SMOKE_VALIDATOR="${ROOT}/scripts/validate-ios-release-model-key.sh" \
    "$@" \
    "${ROOT}/scripts/ios-archive.sh"
}

if run_archive >/dev/null 2>&1; then
  fail "an archive without a public key unexpectedly passed"
fi

invalid_key_path="${TEMP_DIRECTORY}/invalid-key.base64"
printf '%s\n' 'not-a-public-key' > "${invalid_key_path}"
if run_archive KNOCK_MODEL_PUBLIC_KEY_PATH="${invalid_key_path}" >/dev/null 2>&1; then
  fail "an archive with an invalid public key unexpectedly passed"
fi

valid_key_path="${TEMP_DIRECTORY}/valid-key.base64"
python3 - "${valid_key_path}" <<'PY'
import base64
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(base64.b64encode(bytes(range(32))).decode() + "\n")
PY
symlink_path="${TEMP_DIRECTORY}/key-link.base64"
ln -s "${valid_key_path}" "${symlink_path}"
if run_archive KNOCK_MODEL_PUBLIC_KEY_PATH="${symlink_path}" >/dev/null 2>&1; then
  fail "an archive with a symlinked public key unexpectedly passed"
fi

: > "${TEMP_DIRECTORY}/xcodebuild-arguments.log"
run_archive KNOCK_MODEL_PUBLIC_KEY_PATH="${valid_key_path}" >/dev/null
grep -Fq -- 'KNOCK_MODEL_PUBLIC_KEY_PATH=' "${TEMP_DIRECTORY}/xcodebuild-arguments.log" \
  || fail "the archive did not inject a private key-file path"
grep -Fq -- 'INFOPLIST_FILE=' "${TEMP_DIRECTORY}/xcodebuild-arguments.log" \
  || fail "the archive did not inject a private Info.plist path"
public_key="$(tr -d '\r\n' < "${valid_key_path}")"
if grep -Fq -- "${public_key}" "${TEMP_DIRECTORY}/xcodebuild-arguments.log"; then
  fail "the public key was exposed as a process argument"
fi

printf '%s\n' 'ios archive security smoke passed: missing/invalid/symlink keys fail; valid key is embedded through private temporary files'
