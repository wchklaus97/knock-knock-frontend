#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="hk.knockknock.app"
DEVICE_TARGET_DIRECTORY="Documents/KnockKnockVoiceModelUAT"

DEVICE_ID="${KNOCK_DEVICE_UDID:-}"
MODEL_PATH="${KNOCK_VOICE_MODEL_PATH:-}"
MANIFEST_PATH="${KNOCK_VOICE_MODEL_MANIFEST_PATH:-}"
PUBLIC_KEY_PATH="${KNOCK_MODEL_PUBLIC_KEY_PATH:-}"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIRECTORY=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/ios-voice-model-uat.sh \
  --device <CoreDevice UUID> \
  --model </absolute/path/model.litertlm> \
  --manifest </absolute/path/manifest.json> \
  --public-key </absolute/path/public-key.base64>

The equivalent environment variables are KNOCK_DEVICE_UDID,
KNOCK_VOICE_MODEL_PATH, KNOCK_VOICE_MODEL_MANIFEST_PATH, and
KNOCK_MODEL_PUBLIC_KEY_PATH. Public-key content is accepted only through a
file; it is never placed on the command line or printed.
EOF
}

fail() {
  printf 'ios voice-model UAT staging failed: %s\n' "$1" >&2
  exit 1
}

require_value() {
  local option="$1"
  local remaining="$2"
  if ((remaining < 2)); then
    fail "${option} requires a value"
  fi
}

cleanup() {
  if [[ -n "${TEMP_DIRECTORY}" && -d "${TEMP_DIRECTORY}" \
    && "${TEMP_DIRECTORY}" == "${TEMP_ROOT%/}/knock-knock-voice-model-uat."* ]]; then
    rm -rf -- "${TEMP_DIRECTORY}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --device)
      require_value "$1" "$#"
      DEVICE_ID="$2"
      shift 2
      ;;
    --model)
      require_value "$1" "$#"
      MODEL_PATH="$2"
      shift 2
      ;;
    --manifest)
      require_value "$1" "$#"
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --public-key)
      require_value "$1" "$#"
      PUBLIC_KEY_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown option"
      ;;
  esac
done

command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"

[[ "${DEVICE_ID}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
  || fail "--device must be a CoreDevice UUID"

validate_input_file() {
  local path="$1"
  local label="$2"
  local suffix="$3"

  [[ -n "${path}" ]] || fail "${label} path is required"
  [[ "${path}" = /* ]] || fail "${label} path must be absolute"
  [[ "${path}" == *"${suffix}" ]] || fail "${label} path must end in ${suffix}"
  [[ ! -L "${path}" ]] || fail "${label} path must not be a symbolic link"
  [[ -f "${path}" && -r "${path}" && -s "${path}" ]] \
    || fail "${label} path must be a readable, non-empty regular file"
}

validate_input_file "${MODEL_PATH}" "model" ".litertlm"
validate_input_file "${MANIFEST_PATH}" "manifest" ".json"
validate_input_file "${PUBLIC_KEY_PATH}" "public key" ".base64"

[[ -d "${TEMP_ROOT}" && -w "${TEMP_ROOT}" ]] || fail "temporary directory is unavailable"
TEMP_DIRECTORY="$(mktemp -d "${TEMP_ROOT%/}/knock-knock-voice-model-uat.XXXXXX")"
PAYLOAD_DIRECTORY="${TEMP_DIRECTORY}/KnockKnockVoiceModelUAT"
mkdir -m 700 "${PAYLOAD_DIRECTORY}"

cp "${MODEL_PATH}" "${PAYLOAD_DIRECTORY}/model.litertlm"
cp "${MANIFEST_PATH}" "${PAYLOAD_DIRECTORY}/manifest.json"
cp "${PUBLIC_KEY_PATH}" "${PAYLOAD_DIRECTORY}/public-key.base64"
chmod 600 \
  "${PAYLOAD_DIRECTORY}/model.litertlm" \
  "${PAYLOAD_DIRECTORY}/manifest.json" \
  "${PAYLOAD_DIRECTORY}/public-key.base64"

if ! python3 - "${PAYLOAD_DIRECTORY}/manifest.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
with path.open("rb") as handle:
    payload = handle.read(1_048_577)
if not payload or len(payload) > 1_048_576:
    raise SystemExit(1)
json.loads(payload)
PY
then
  fail "manifest must contain valid JSON no larger than 1 MiB"
fi

if ! python3 - "${PAYLOAD_DIRECTORY}/public-key.base64" <<'PY'
import base64
from pathlib import Path
import sys

path = Path(sys.argv[1])
encoded = path.read_text(encoding="utf-8").strip()
try:
    decoded = base64.b64decode(encoded, validate=True)
except (ValueError, UnicodeError):
    raise SystemExit(1)
if len(decoded) != 32:
    raise SystemExit(1)
PY
then
  fail "public key file must contain one valid 32-byte Ed25519 key in base64"
fi

touch "${PAYLOAD_DIRECTORY}/required"
chmod 600 "${PAYLOAD_DIRECTORY}/required"

APP_LIST_JSON="${TEMP_DIRECTORY}/apps.json"
if ! xcrun devicectl device info apps \
  --device "${DEVICE_ID}" \
  --bundle-id "${BUNDLE_ID}" \
  --json-output "${APP_LIST_JSON}" \
  --quiet >/dev/null; then
  fail "the device or installed app could not be queried"
fi

if ! python3 - "${APP_LIST_JSON}" "${BUNDLE_ID}" <<'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = sys.argv[2]

def contains_expected_bundle(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower() in {"bundleidentifier", "bundleid"} and item == expected:
                return True
            if contains_expected_bundle(item):
                return True
        return False
    if isinstance(value, list):
        return any(contains_expected_bundle(item) for item in value)
    return False

if not contains_expected_bundle(payload.get("result")):
    raise SystemExit(1)
PY
then
  fail "${BUNDLE_ID} is not installed on the selected device"
fi

COPY_JSON="${TEMP_DIRECTORY}/copy.json"
if ! xcrun devicectl device copy to \
  --device "${DEVICE_ID}" \
  --source "${PAYLOAD_DIRECTORY}" \
  --destination "${DEVICE_TARGET_DIRECTORY}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --remove-existing-content false \
  --json-output "${COPY_JSON}" \
  --quiet >/dev/null; then
  fail "the validated UAT payload could not be staged"
fi

printf 'Staged the required voice-model UAT payload at %s for %s.\n' \
  "${DEVICE_TARGET_DIRECTORY}" "${BUNDLE_ID}"
printf 'Run this exact follow-up command (not executed by this script):\n'
printf 'cd %q && env -u KNOCK_VOICE_MODEL_PATH -u KNOCK_VOICE_MODEL_MANIFEST_PATH -u KNOCK_MODEL_PUBLIC_KEY_BASE64 xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge -destination %q -only-testing:VoiceAgentBridgeTests/VoiceModelGoldenEvaluationTests/testSignedModelMeetsAccuracySafetyAndLatencyGates test\n' \
  "${ROOT_DIR}/apps/ios" "platform=iOS,id=${DEVICE_ID}"
