#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPROVED_STAGING_ORIGIN="https://knock-knock-backend-staging.wch-klaus.workers.dev"
DEVICE_ID="${KNOCK_DEVICE_UDID:-}"
API_BASE="${KNOCK_API_BASE_URL:-}"
PUBLIC_KEY_PATH="${KNOCK_MODEL_PUBLIC_KEY_PATH:-}"
SCHEDULED_URL="${KNOCK_LOCAL_SCHEDULED_URL:-}"
COUNTDOWN_SECONDS="${KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS:-5}"
HOLD_SECONDS="${KNOCK_PHYSICAL_VOICE_HOLD_SECONDS:-12}"
VOICE_RUNTIME="${KNOCK_EXPECTED_VOICE_RUNTIME:-signed-gemma}"
MANUAL_CAPTURE="${KNOCK_PHYSICAL_VOICE_MANUAL_CAPTURE:-0}"
EXPECTATION_MODE="${KNOCK_PHYSICAL_VOICE_EXPECTATION_MODE:-history}"
PERMISSIONS_PREGRANTED="${KNOCK_PHYSICAL_VOICE_PERMISSIONS_PREGRANTED:-0}"
ARTIFACTS_DIR="${KNOCK_VOICE_E2E_ARTIFACTS_DIR:-}"
DERIVED_DATA=""
PRIVATE_PUBLIC_KEY_PATH=""
PRIVATE_INFO_PLIST_PATH=""
SCHEDULED_PID=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/ios-physical-voice-e2e.sh \
  --device <CoreDevice UUID> \
  --api-base <https://knock-knock-backend-staging.wch-klaus.workers.dev or http://Mac-LAN-IP:8787> \
  [--public-key </absolute/path/public-key.base64>] \
  [--runtime <signed-gemma|safe-parser>] \
  [--scheduled-url <http://127.0.0.1:8787/__scheduled>] \
  [--countdown <3-30>] \
  [--hold-seconds <8-20>] \
  [--manual-capture] \
  --permissions-pregranted \
  [--expectation <history|high-risk|clarification>] \
  [--artifacts-dir </absolute/path>]

This is an opt-in physical-iPhone UAT. It never deploys or changes backend
configuration. Automated capture remains the default. With --manual-capture,
the operator presses, holds, and releases voice.dock while XCUITest monitors.
Microphone and Speech Recognition permissions must already be granted; the
harness never presses the production voice dock merely to prime permissions.
The script prints the exact golden-set phrase for the selected expectation.
The public key is required only for the signed-gemma runtime. The iPhone 13 Pro
safe-parser runtime does not download or trust a model artifact.
EOF
}

fail() {
  printf 'physical voice E2E preflight failed: %s\n' "$1" >&2
  exit 1
}

require_value() {
  (($# >= 2)) || fail "$1 requires a value"
}

cleanup() {
  if [[ -n "${SCHEDULED_PID}" ]]; then
    kill "${SCHEDULED_PID}" >/dev/null 2>&1 || true
    wait "${SCHEDULED_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DERIVED_DATA}" && -d "${DERIVED_DATA}" \
    && "${DERIVED_DATA}" == "${TMPDIR:-/tmp}"/knock-voice-e2e-derived.* ]]; then
    find "${DERIVED_DATA}" -depth -delete
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --device)
      require_value "$@"
      DEVICE_ID="$2"
      shift 2
      ;;
    --api-base)
      require_value "$@"
      API_BASE="$2"
      shift 2
      ;;
    --public-key)
      require_value "$@"
      PUBLIC_KEY_PATH="$2"
      shift 2
      ;;
    --scheduled-url)
      require_value "$@"
      SCHEDULED_URL="$2"
      shift 2
      ;;
    --countdown)
      require_value "$@"
      COUNTDOWN_SECONDS="$2"
      shift 2
      ;;
    --hold-seconds)
      require_value "$@"
      HOLD_SECONDS="$2"
      shift 2
      ;;
    --manual-capture)
      MANUAL_CAPTURE=1
      shift
      ;;
    --permissions-pregranted)
      PERMISSIONS_PREGRANTED=1
      shift
      ;;
    --expectation)
      require_value "$@"
      EXPECTATION_MODE="$2"
      shift 2
      ;;
    --runtime)
      require_value "$@"
      VOICE_RUNTIME="$2"
      shift 2
      ;;
    --artifacts-dir)
      require_value "$@"
      ARTIFACTS_DIR="$2"
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

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v grep >/dev/null 2>&1 || fail "grep is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v tee >/dev/null 2>&1 || fail "tee is required"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"

[[ "${DEVICE_ID}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
  || fail "--device must be a CoreDevice UUID"
if [[ ! "${COUNTDOWN_SECONDS}" =~ ^[0-9]+$ ]] \
  || ((COUNTDOWN_SECONDS < 3 || COUNTDOWN_SECONDS > 30)); then
  fail "--countdown must be from 3 to 30 seconds"
fi
[[ "${VOICE_RUNTIME}" == "signed-gemma" || "${VOICE_RUNTIME}" == "safe-parser" ]] \
  || fail "--runtime must be signed-gemma or safe-parser"
[[ "${MANUAL_CAPTURE}" == "0" || "${MANUAL_CAPTURE}" == "1" ]] \
  || fail "KNOCK_PHYSICAL_VOICE_MANUAL_CAPTURE must be 0 or 1"
[[ "${PERMISSIONS_PREGRANTED}" == "1" ]] \
  || fail "Microphone and Speech Recognition permissions must be pre-granted; pass --permissions-pregranted"
case "${EXPECTATION_MODE}" in
  history)
    OPERATOR_PHRASE='Show me what happened today'
    ;;
  high-risk)
    OPERATOR_PHRASE='Send John a message saying I am on my way'
    ;;
  clarification)
    OPERATOR_PHRASE='Send him a message saying yes'
    ;;
  *)
    fail "--expectation must be history, high-risk, or clarification"
    ;;
esac
if [[ ! "${HOLD_SECONDS}" =~ ^([0-9]+)(\.[0-9]+)?$ ]] \
  || ! python3 - "${HOLD_SECONDS}" <<'PY'
import sys
value = float(sys.argv[1])
raise SystemExit(0 if 8 <= value <= 20 else 1)
PY
then
  fail "--hold-seconds must be from 8 to 20 seconds"
fi
[[ -n "${API_BASE}" ]] || fail "--api-base is required"
API_BASE="${API_BASE%/}"
python3 - "${API_BASE}" "${APPROVED_STAGING_ORIGIN}" <<'PY' \
  || fail "--api-base must be the exact Knock Knock staging origin or an RFC1918 HTTP origin"
import ipaddress
import sys
from urllib.parse import urlparse

url = urlparse(sys.argv[1])
approved_staging = sys.argv[2]
if sys.argv[1] == approved_staging:
    raise SystemExit(0)
if (
    url.scheme != "http"
    or not url.hostname
    or url.username is not None
    or url.password is not None
    or url.path not in {"", "/"}
    or url.query
    or url.fragment
):
    raise SystemExit(1)
try:
    address = ipaddress.ip_address(url.hostname)
    _ = url.port
except ValueError:
    raise SystemExit(1)
private_lan = (
    address in ipaddress.ip_network("10.0.0.0/8")
    or address in ipaddress.ip_network("172.16.0.0/12")
    or address in ipaddress.ip_network("192.168.0.0/16")
)
raise SystemExit(0 if private_lan else 1)
PY

if [[ "${VOICE_RUNTIME}" == "signed-gemma" ]]; then
  [[ "${PUBLIC_KEY_PATH}" = /* && -f "${PUBLIC_KEY_PATH}" \
    && ! -L "${PUBLIC_KEY_PATH}" && -r "${PUBLIC_KEY_PATH}" ]] \
    || fail "--public-key must be an absolute readable regular file, not a symlink"
  python3 - "${PUBLIC_KEY_PATH}" <<'PY' || fail "public key must be one base64-encoded 32-byte Ed25519 key"
import base64
import pathlib
import sys

try:
    encoded = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
    raw = base64.b64decode(encoded, validate=True)
except (ValueError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if len(raw) == 32 else 1)
PY
fi

if [[ -n "${SCHEDULED_URL}" \
  && ! "${SCHEDULED_URL}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/__scheduled$ ]]; then
  fail "--scheduled-url is restricted to an explicit loopback /__scheduled endpoint"
fi

DEVICE_LIST="$(xcrun devicectl list devices)"
grep -Fq "${DEVICE_ID}" <<<"${DEVICE_LIST}" || fail "selected iPhone is not paired with this Mac"
DEVICE_ROW="$(grep -F "${DEVICE_ID}" <<<"${DEVICE_LIST}")"
grep -Eq 'connected|available \(paired\)' <<<"${DEVICE_ROW}" \
  || fail "selected iPhone is not available"
if [[ "${VOICE_RUNTIME}" == "safe-parser" ]]; then
  grep -Eq 'iPhone14,(2|3)' <<<"${DEVICE_ROW}" \
    || fail "safe-parser UAT is restricted to the iPhone 13 Pro device policy"
fi

HEALTH="$(curl -fsS --max-time 15 "${API_BASE}/health")" \
  || fail "backend health endpoint is unreachable"
python3 - "${HEALTH}" <<'PY' || fail "backend health did not report ok=true"
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
raise SystemExit(0 if payload.get("ok") is True else 1)
PY
if [[ "${EXPECTATION_MODE}" == "high-risk" ]]; then
  python3 - "${HEALTH}" <<'PY' \
    || fail "high-risk UAT requires health action_provider_ready=false"
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
raise SystemExit(0 if payload.get("action_provider_ready") is False else 1)
PY
fi
if [[ "${VOICE_RUNTIME}" == "signed-gemma" ]]; then
  METRICS="$(curl -fsS --max-time 15 "${API_BASE}/metrics")" \
    || fail "backend metrics endpoint is unreachable"
  grep -Eq '^knock_knock_model_enabled[[:space:]]+1([[:space:]]|$)' <<<"${METRICS}" \
    || fail "backend voice model is disabled; configure a real signed artifact before UAT"
fi

if [[ -z "${ARTIFACTS_DIR}" ]]; then
  ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/knock-voice-e2e-artifacts.XXXXXX")"
else
  [[ "${ARTIFACTS_DIR}" = /* ]] || fail "--artifacts-dir must be absolute"
  mkdir -p "${ARTIFACTS_DIR}"
  chmod 700 "${ARTIFACTS_DIR}"
fi
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/knock-voice-e2e-derived.XXXXXX")"
MODEL_BUILD_SETTINGS=("KNOCK_EXPECTED_VOICE_RUNTIME=${VOICE_RUNTIME}")
if [[ "${VOICE_RUNTIME}" == "signed-gemma" ]]; then
  PRIVATE_PUBLIC_KEY_PATH="${DERIVED_DATA}/model-public-key.base64"
  PRIVATE_INFO_PLIST_PATH="${DERIVED_DATA}/VoiceAgentBridge-Info.plist"
  cp "${PUBLIC_KEY_PATH}" "${PRIVATE_PUBLIC_KEY_PATH}"
  python3 - \
    "${ROOT_DIR}/apps/ios/VoiceAgentBridge/Info.plist" \
    "${PRIVATE_PUBLIC_KEY_PATH}" \
    "${PRIVATE_INFO_PLIST_PATH}" <<'PY'
import pathlib
import plistlib
import sys

source_path = pathlib.Path(sys.argv[1])
key_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])
with source_path.open("rb") as handle:
    payload = plistlib.load(handle)
payload["KNOCK_MODEL_PUBLIC_KEY_BASE64"] = key_path.read_text(
    encoding="utf-8"
).strip()
with output_path.open("wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
  chmod 600 "${PRIVATE_PUBLIC_KEY_PATH}" "${PRIVATE_INFO_PLIST_PATH}"
  MODEL_BUILD_SETTINGS+=(
    "KNOCK_MODEL_PUBLIC_KEY_PATH=${PRIVATE_PUBLIC_KEY_PATH}"
    "INFOPLIST_FILE=${PRIVATE_INFO_PLIST_PATH}"
  )
fi

if [[ -n "${SCHEDULED_URL}" ]]; then
  (
    while true; do
      curl -fsS --max-time 5 "${SCHEDULED_URL}" >/dev/null || true
      sleep 3
    done
  ) &
  SCHEDULED_PID="$!"
fi

printf '%s\n' \
  'Physical voice UAT is ready.' \
  'Microphone and Speech Recognition permissions: pre-granted.' \
  "Approved backend origin: ${API_BASE}" \
  "Expectation mode: ${EXPECTATION_MODE}" \
  "Say exactly: ${OPERATOR_PHRASE}"
if [[ "${MANUAL_CAPTURE}" == "1" ]]; then
  printf '%s\n' \
    'MANUAL CAPTURE: press and hold voice.dock on the iPhone.' \
    'Wait for Listening, speak the exact phrase, then release after one second of silence.'
else
  printf '%s\n' \
    'Watch the iPhone; speak only after the dock shows Listening.' \
    "The automated hold lasts ${HOLD_SECONDS} seconds; finish with one second of silence."
fi
if [[ "${EXPECTATION_MODE}" == "high-risk" ]]; then
  printf '%s\n' \
    'Provider effects are disabled by the verified health precondition.' \
    'Do not tap Confirm. The test observes a stable awaiting_confirmation window, then cancels.'
fi
if [[ "${EXPECTATION_MODE}" == "history" ]]; then
  printf '%s\n' 'After the UI succeeds, confirm that TTS says: History search completed.'
fi

set +e
(
  cd "${ROOT_DIR}/apps/ios"
  xcodebuild \
    -project VoiceAgentBridge.xcodeproj \
    -scheme VoiceAgentBridge \
    -configuration Staging \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${ARTIFACTS_DIR}/physical-voice.xcresult" \
    -allowProvisioningUpdates \
    -only-testing:VoiceAgentBridgeUITests/VoiceAgentBridgeUITests/testPhysicalVoiceProductionPath \
    KNOCK_API_BASE_URL="${API_BASE}" \
    "${MODEL_BUILD_SETTINGS[@]}" \
    KNOCK_RUN_PHYSICAL_VOICE_E2E=1 \
    KNOCK_PHYSICAL_VOICE_MANUAL_CAPTURE="${MANUAL_CAPTURE}" \
    KNOCK_PHYSICAL_VOICE_EXPECTATION_MODE="${EXPECTATION_MODE}" \
    KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS="${COUNTDOWN_SECONDS}" \
    KNOCK_PHYSICAL_VOICE_HOLD_SECONDS="${HOLD_SECONDS}" \
    test
) 2>&1 | tee "${ARTIFACTS_DIR}/xcodebuild.log"
status="${PIPESTATUS[0]}"
set -e

printf 'Physical voice UAT artifacts: %s\n' "${ARTIFACTS_DIR}"
if ((status != 0)); then
  fail "Xcode physical voice UAT failed (see the artifact log)"
fi
case "${EXPECTATION_MODE}" in
  history)
    printf '%s\n' \
      'History row oracle passed: one durable command and a stable canonical replay response.' \
      'This fixture replay does not prove provider-effect dedupe. Composite authority remains the iOS cold-start replay unit plus the backend provider lifecycle gate.'
    ;;
  high-risk)
    printf '%s\n' \
      'High-risk fail-closed oracle passed: provider disabled, stable awaiting_confirmation, never confirmed, then cancelled.'
    ;;
  clarification)
    printf '%s\n' \
      'Clarification oracle passed: zero backend command delta sustained for 30 seconds.'
    ;;
esac
printf '%s\n' \
  'Human sign-off remains required for pre-granted permissions, spoken input, and audible TTS.'
