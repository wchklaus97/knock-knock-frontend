#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="${KNOCK_DEVICE_UDID:-}"
API_BASE="${KNOCK_API_BASE_URL:-}"
PUBLIC_KEY_PATH="${KNOCK_MODEL_PUBLIC_KEY_PATH:-}"
SCHEDULED_URL="${KNOCK_LOCAL_SCHEDULED_URL:-}"
COUNTDOWN_SECONDS="${KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS:-5}"
ARTIFACTS_DIR="${KNOCK_VOICE_E2E_ARTIFACTS_DIR:-}"
DERIVED_DATA=""
XCCONFIG_PATH=""
SCHEDULED_PID=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/ios-physical-voice-e2e.sh \
  --device <CoreDevice UUID> \
  --api-base <https://staging.example or http://Mac-LAN-IP:8787> \
  --public-key </absolute/path/public-key.base64> \
  [--scheduled-url <http://127.0.0.1:8787/__scheduled>] \
  [--countdown <3-30>] \
  [--artifacts-dir </absolute/path>]

This is an opt-in physical-iPhone UAT. It never deploys or changes backend
configuration. The operator must grant first-use permissions, speak exactly
"Show me what happened today", keep holding through at least one second of
silence, and confirm hearing "History search completed."
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
[[ -n "${API_BASE}" ]] || fail "--api-base is required"
API_BASE="${API_BASE%/}"
python3 - "${API_BASE}" <<'PY' || fail "--api-base must be HTTPS or a local-network HTTP URL"
import ipaddress
import sys
from urllib.parse import urlparse

url = urlparse(sys.argv[1])
if url.scheme == "https" and url.hostname:
    raise SystemExit(0)
if url.scheme != "http" or not url.hostname:
    raise SystemExit(1)
if url.hostname in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit(1)
try:
    raise SystemExit(0 if ipaddress.ip_address(url.hostname).is_private else 1)
except ValueError:
    raise SystemExit(1)
PY

[[ "${PUBLIC_KEY_PATH}" = /* && -f "${PUBLIC_KEY_PATH}" \
  && ! -L "${PUBLIC_KEY_PATH}" && -r "${PUBLIC_KEY_PATH}" ]] \
  || fail "--public-key must be an absolute readable regular file, not a symlink"
PUBLIC_KEY="$(tr -d '\r\n' < "${PUBLIC_KEY_PATH}")"
python3 - "${PUBLIC_KEY}" <<'PY' || fail "public key must be one base64-encoded 32-byte Ed25519 key"
import base64
import sys

try:
    raw = base64.b64decode(sys.argv[1], validate=True)
except (ValueError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if len(raw) == 32 else 1)
PY

if [[ -n "${SCHEDULED_URL}" \
  && ! "${SCHEDULED_URL}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/__scheduled$ ]]; then
  fail "--scheduled-url is restricted to an explicit loopback /__scheduled endpoint"
fi

DEVICE_LIST="$(xcrun devicectl list devices)"
grep -Fq "${DEVICE_ID}" <<<"${DEVICE_LIST}" || fail "selected iPhone is not paired with this Mac"
grep -F "${DEVICE_ID}" <<<"${DEVICE_LIST}" | grep -Eq 'connected|available \(paired\)' \
  || fail "selected iPhone is not available"

HEALTH="$(curl -fsS --max-time 15 "${API_BASE}/health")" \
  || fail "backend health endpoint is unreachable"
grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<<"${HEALTH}" \
  || fail "backend health did not report ok=true"
METRICS="$(curl -fsS --max-time 15 "${API_BASE}/metrics")" \
  || fail "backend metrics endpoint is unreachable"
grep -Eq '^knock_knock_model_enabled[[:space:]]+1([[:space:]]|$)' <<<"${METRICS}" \
  || fail "backend voice model is disabled; configure a real signed artifact before UAT"

if [[ -z "${ARTIFACTS_DIR}" ]]; then
  ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/knock-voice-e2e-artifacts.XXXXXX")"
else
  [[ "${ARTIFACTS_DIR}" = /* ]] || fail "--artifacts-dir must be absolute"
  mkdir -p "${ARTIFACTS_DIR}"
  chmod 700 "${ARTIFACTS_DIR}"
fi
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/knock-voice-e2e-derived.XXXXXX")"
XCCONFIG_PATH="${DERIVED_DATA}/VoiceE2E.xcconfig"
printf 'KNOCK_MODEL_PUBLIC_KEY_BASE64 = "%s"\n' "${PUBLIC_KEY}" > "${XCCONFIG_PATH}"
chmod 600 "${XCCONFIG_PATH}"

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
  'When the test prints SPEAK NOW, say: Show me what happened today' \
  'Keep holding through at least one second of silence.' \
  'After the UI succeeds, confirm that TTS says: History search completed.'

set +e
(
  cd "${ROOT_DIR}/apps/ios"
  xcodebuild \
    -project VoiceAgentBridge.xcodeproj \
    -scheme VoiceAgentBridge \
    -configuration Staging \
    -xcconfig "${XCCONFIG_PATH}" \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${ARTIFACTS_DIR}/physical-voice.xcresult" \
    -allowProvisioningUpdates \
    -only-testing:VoiceAgentBridgeUITests/VoiceAgentBridgeUITests/testPhysicalVoiceProductionPath \
    KNOCK_API_BASE_URL="${API_BASE}" \
    KNOCK_RUN_PHYSICAL_VOICE_E2E=1 \
    KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS="${COUNTDOWN_SECONDS}" \
    test
) 2>&1 | tee "${ARTIFACTS_DIR}/xcodebuild.log"
status="${PIPESTATUS[0]}"
set -e

printf 'Physical voice UAT artifacts: %s\n' "${ARTIFACTS_DIR}"
if ((status != 0)); then
  fail "Xcode physical voice UAT failed (see the artifact log)"
fi
printf '%s\n' \
  'Automated UI/backend oracle passed.' \
  'Human sign-off remains required for microphone permission, spoken input, and audible TTS.'
