#!/usr/bin/env bash
# Real-device two-turn sign-off: two decisions, one session, one chat_id.
# Human taps remain required for both phone turns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
DEVICE_UDID="${KNOCK_DEVICE_UDID:-}"
DEVICE_LABEL="${KNOCK_DEVICE_NAME:-iPhone 13 Pro}"
BUNDLE_ID="hk.knockknock.app"
PROJECT_BUILD_VERSION="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT/apps/ios/project.yml")"
EXPECTED_BUNDLE_VERSION="${KNOCK_EXPECTED_BUNDLE_VERSION:-$PROJECT_BUILD_VERSION}"
BUILD_LABEL="build-${EXPECTED_BUNDLE_VERSION}"
WAIT_SECONDS="${PHONE_WAIT_SECONDS:-300}"

if [[ -z "$EXPECTED_BUNDLE_VERSION" ]]; then
  echo "ERROR: set KNOCK_EXPECTED_BUNDLE_VERSION or define CURRENT_PROJECT_VERSION in apps/ios/project.yml." >&2
  exit 2
fi

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(xcrun devicectl list devices | awk -v wanted="$DEVICE_LABEL" 'index($0, wanted) { for (i = 1; i <= NF; i++) if (length($i) == 36 && $i ~ /^[0-9A-Fa-f-]+$/) { print $i; exit } }')"
fi
if [[ -z "$DEVICE_UDID" ]]; then
  echo "ERROR: connect $DEVICE_LABEL or set KNOCK_DEVICE_UDID." >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh" >/dev/null
HEALTH="$(curl -sf "$API/health")"
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "Physical multi-turn sign-off requires the Rust Worker at $API" >&2
  echo "$HEALTH" | jq '{ok,api,runtime,version}' >&2
  exit 1
}

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
test -n "$LAN_IP" || { echo "ERROR: no en0 LAN address." >&2; exit 1; }
echo "iPhone API URL should be http://$LAN_IP:8787"

APP_INFO="$(xcrun devicectl device info apps --device "$DEVICE_UDID" --bundle-id "$BUNDLE_ID")"
echo "$APP_INFO"
if ! echo "$APP_INFO" | grep -q "Knock Knock"; then
  echo "ERROR: $BUNDLE_ID is not installed on the device." >&2
  exit 1
fi
if ! echo "$APP_INFO" | awk -v expected="$EXPECTED_BUNDLE_VERSION" \
  '$1 == "Knock" && $2 == "Knock" && $NF == expected { found = 1 } END { exit !found }'; then
  echo "ERROR: expected bundle version $EXPECTED_BUNDLE_VERSION ($BUILD_LABEL)." >&2
  exit 1
fi
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null

RUN_TAG="phone-multiturn-$(date +%s)-$RANDOM"
CHAT_ID="chat-$RUN_TAG"
cd "$ROOT"
SESSION_JSON="$(pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --skill deploy.result --title "Phone multi-turn pilot" --chat "$CHAT_ID")"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$SESSION_JSON")"
test -n "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$SESSION_JSON")" = "$CHAT_ID"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" --status running --message "Phone multi-turn turn 1" >/dev/null
EVENT_ONE="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" --status needs_user --idemp "$RUN_TAG-event-1" \
  --summary "Turn 1: review the first checkpoint" \
  --service codex --env local --fact_status "Turn 1" --actions rollback)"
test "$(jq -r '.pushed // false' <<<"$EVENT_ONE")" = "true"

echo ""
echo "TURN 1 / 2 — same session: $SESSION_ID"
echo "Chat: $CHAT_ID"
echo "On iPhone 13 Pro: Review request → rollback → Confirm."
PHYSICAL_SESSION_ID="$SESSION_ID" PHONE_WAIT_SECONDS="$WAIT_SECONDS" \
  bash "$ROOT/scripts/physical-signoff-watch.sh"

RESUMED="$(pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --session "$SESSION_ID" --skill deploy.result --chat "$CHAT_ID")"
test "$(jq -r '.session_id // empty' <<<"$RESUMED")" = "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$RESUMED")" = "$CHAT_ID"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" --status running --message "Phone multi-turn turn 2" >/dev/null
EVENT_TWO="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" --status needs_user --idemp "$RUN_TAG-event-2" \
  --summary "Turn 2: review the follow-up checkpoint in the same chat" \
  --service codex --env local --fact_status "Turn 2" --actions ack)"
test "$(jq -r '.pushed // false' <<<"$EVENT_TWO")" = "true"

echo ""
echo "TURN 2 / 2 — same session: $SESSION_ID"
echo "Chat: $CHAT_ID"
echo "On iPhone 13 Pro: open the second knock and tap ack."
PHYSICAL_SESSION_ID="$SESSION_ID" PHONE_WAIT_SECONDS="$WAIT_SECONDS" \
  bash "$ROOT/scripts/physical-signoff-watch.sh"

FINAL="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" "$API/v1/sessions/$SESSION_ID")"
test "$(jq -r '.session_id // empty' <<<"$FINAL")" = "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$FINAL")" = "$CHAT_ID"
test "$(jq -r '.state // empty' <<<"$FINAL")" = "running"
printf 'physical multi-turn sign-off passed: session=%s chat=%s state=running backend=rust\n' "$SESSION_ID" "$CHAT_ID"
