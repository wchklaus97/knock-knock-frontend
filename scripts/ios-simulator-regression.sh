#!/usr/bin/env bash
# Deterministic iOS Simulator regression for the production decision surface.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_TEST_DESTINATION"
else
  SIMULATOR_ID="$(xcrun simctl list devices available \
    | sed -n 's/.*iPhone 15 Pro (\([0-9A-Fa-f-]\{36\}\)).*/\1/p' \
    | head -n 1)"
  if [[ -z "$SIMULATOR_ID" ]]; then
    echo "No available iPhone 15 Pro simulator found; set IOS_TEST_DESTINATION explicitly." >&2
    exit 2
  fi
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

if [[ -z "${BRIDGE_API_URL:-}" && -f "$ROOT/.env.agent" ]]; then
  BRIDGE_API_URL="$(sed -n 's/^BRIDGE_API_URL=//p' "$ROOT/.env.agent" | head -n 1)"
  BRIDGE_API_URL="${BRIDGE_API_URL#\"}"
  BRIDGE_API_URL="${BRIDGE_API_URL%\"}"
  export BRIDGE_API_URL
fi
BRIDGE_API_URL="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
BRIDGE_API_URL="${BRIDGE_API_URL%/}"
export BRIDGE_API_URL

# A local Worker must be the only listener for the test endpoint. Multiple
# wrangler processes can share a port on macOS, which makes requests randomly
# hit different D1 databases and produces misleading fixture failures.
if [[ "$BRIDGE_API_URL" =~ ^http://(127\.0\.0\.1|localhost):([0-9]+)$ ]] && command -v lsof >/dev/null 2>&1; then
  local_port="${BASH_REMATCH[2]}"
  listener_count="$(lsof -nP -iTCP:"$local_port" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')"
  if [[ "$listener_count" -gt 1 ]]; then
    echo "Multiple local Worker processes are listening on $BRIDGE_API_URL; use one isolated Worker (for example port 8798) before running iOS regression." >&2
    exit 2
  fi
fi

echo "== API health =="
HEALTH="$(curl -sf "${BRIDGE_API_URL}/health")"
echo "$HEALTH" | jq '{ok,api,runtime,version}'
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "iOS regression must run against the canonical Rust Worker." >&2
  exit 1
}

echo "== generate Xcode project =="
cd "$ROOT/apps/ios"
xcodegen generate

echo "== iOS Simulator regression =="
export GIT_LFS_SKIP_SMUDGE="${GIT_LFS_SKIP_SMUDGE:-1}"
xcodebuild \
  -project VoiceAgentBridge.xcodeproj \
  -scheme VoiceAgentBridge \
  -destination "$DESTINATION" \
  KNOCK_API_BASE_URL="$BRIDGE_API_URL" \
  KNOCK_UI_TEST_API_BASE_URL="$BRIDGE_API_URL" \
  test
