#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'release model trust-key validation failed: %s\n' "$1" >&2
  exit 1
}

if [[ "${CONFIGURATION:-Release}" != "Release" ]]; then
  exit 0
fi

path="${KNOCK_MODEL_PUBLIC_KEY_PATH:-}"
[[ "${path}" = /* && -f "${path}" && ! -L "${path}" && -r "${path}" ]] \
  || fail "KNOCK_MODEL_PUBLIC_KEY_PATH must be an absolute readable regular file, not a symlink"
key="$(tr -d '\r\n' < "${path}")"

KNOCK_VALIDATED_MODEL_PUBLIC_KEY="${key}" python3 - <<'PY' \
  || fail "KNOCK_MODEL_PUBLIC_KEY_BASE64 must be one base64-encoded 32-byte Ed25519 public key"
import base64
import os

value = os.environ.get("KNOCK_VALIDATED_MODEL_PUBLIC_KEY", "")
try:
    raw = base64.b64decode(value, validate=True)
except (ValueError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if len(raw) == 32 else 1)
PY

info_plist="${INFOPLIST_FILE:-}"
[[ -n "${info_plist}" ]] \
  || fail "path-based key injection requires a private INFOPLIST_FILE"
if [[ "${info_plist}" != /* ]]; then
  info_plist="${SRCROOT:-}/${info_plist}"
fi
[[ -f "${info_plist}" && ! -L "${info_plist}" && -r "${info_plist}" ]] \
  || fail "INFOPLIST_FILE must be a readable regular file, not a symlink"
KNOCK_VALIDATED_MODEL_PUBLIC_KEY="${key}" \
KNOCK_VALIDATED_INFO_PLIST="${info_plist}" python3 - <<'PY' \
  || fail "the private Info.plist must embed the validated model public key"
import os
import plistlib

with open(os.environ["KNOCK_VALIDATED_INFO_PLIST"], "rb") as handle:
    payload = plistlib.load(handle)
raise SystemExit(
    0 if payload.get("KNOCK_MODEL_PUBLIC_KEY_BASE64")
    == os.environ["KNOCK_VALIDATED_MODEL_PUBLIC_KEY"] else 1
)
PY

printf '%s\n' 'Release voice-model trust key validation passed.'
