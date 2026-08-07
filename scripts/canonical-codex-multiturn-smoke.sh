#!/usr/bin/env bash
# Canonical Codex multi-turn smoke: two phone decisions on one session/chat.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"

command -v codex >/dev/null || { echo "codex CLI is required" >&2; exit 1; }
CODEX_MCP_LIST="$(codex mcp list 2>/dev/null)"
grep -q 'voice-agent-bridge' <<<"$CODEX_MCP_LIST" || {
  echo "Codex MCP entry voice-agent-bridge is not configured" >&2
  exit 1
}

# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh" >/dev/null
HEALTH="$(curl -sf "$API/health")"
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "Canonical Codex multi-turn smoke requires the Rust Worker at $API" >&2
  echo "$HEALTH" | jq '{ok,api,runtime,version}' >&2
  exit 1
}

RUN_TAG="codex-multiturn-$(date +%s)-$RANDOM"
CHAT_ID="chat-$RUN_TAG"
SESSION_JSON="$(cd "$ROOT" && pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --skill deploy.result \
  --title "Codex multi-turn smoke" \
  --chat "$CHAT_ID")"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$SESSION_JSON")"
test -n "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$SESSION_JSON")" = "$CHAT_ID"

cd "$ROOT"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" --status running --message "Codex multi-turn turn 1" >/dev/null

EVENT_ONE="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" --status needs_user --idemp "$RUN_TAG-event-1" \
  --summary "Turn 1: approve the first safe checkpoint" \
  --service codex --env test --fact_status "Turn 1" --actions ack)"
test "$(jq -r '.pushed // false' <<<"$EVENT_ONE")" = "true"
EVENT_ONE_ID="$(jq -r '.event_id // empty' <<<"$EVENT_ONE")"

EMAIL="${E2E_EMAIL:-e2e-1785931570@local.test}"
PASSWORD="${E2E_PASSWORD:-password123}"
AUTH="$(curl -sf -X POST "$API/v1/auth/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg email "$EMAIL" --arg password "$PASSWORD" '{email:$email,password:$password}')")"
USER_TOKEN="$(jq -r '.token // empty' <<<"$AUTH")"
test -n "$USER_TOKEN"

PHONE_ONE="$(curl -sf -X POST "$API/v1/phone/sessions/$SESSION_ID/reply" \
  -H "Authorization: Bearer $USER_TOKEN" -H 'content-type: application/json' \
  -d '{"action_key":"ack","utterance":"确认第一轮"}')"
test "$(jq -r '.needs_confirm // false' <<<"$PHONE_ONE")" = "false"
test "$(jq -r '.session.session_id // empty' <<<"$PHONE_ONE")" = "$SESSION_ID"

PENDING_ONE="$(pnpm --filter @vab/mcp exec tsx src/cli.ts pending --session "$SESSION_ID" --claim true)"
ACTION_ONE="$(jq -r '.actions[0].action_id // empty' <<<"$PENDING_ONE")"
test -n "$ACTION_ONE"
RESULT_ONE="$(pnpm --filter @vab/mcp exec tsx src/cli.ts result --action "$ACTION_ONE" --ok true --message "Turn 1 complete")"
test "$(jq -r '.status // empty' <<<"$RESULT_ONE")" = "done"

RESUMED="$(pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --session "$SESSION_ID" --skill deploy.result --chat "$CHAT_ID")"
test "$(jq -r '.session_id // empty' <<<"$RESUMED")" = "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$RESUMED")" = "$CHAT_ID"

pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" --status running --message "Codex multi-turn turn 2" >/dev/null
EVENT_TWO="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" --status needs_user --idemp "$RUN_TAG-event-2" \
  --summary "Turn 2: approve the follow-up checkpoint in the same chat" \
  --service codex --env test --fact_status "Turn 2" --actions ack)"
test "$(jq -r '.pushed // false' <<<"$EVENT_TWO")" = "true"
EVENT_TWO_ID="$(jq -r '.event_id // empty' <<<"$EVENT_TWO")"

PHONE_TWO="$(curl -sf -X POST "$API/v1/phone/sessions/$SESSION_ID/reply" \
  -H "Authorization: Bearer $USER_TOKEN" -H 'content-type: application/json' \
  -d '{"action_key":"ack","utterance":"确认第二轮"}')"
test "$(jq -r '.needs_confirm // false' <<<"$PHONE_TWO")" = "false"
test "$(jq -r '.session.session_id // empty' <<<"$PHONE_TWO")" = "$SESSION_ID"

PENDING_TWO="$(pnpm --filter @vab/mcp exec tsx src/cli.ts pending --session "$SESSION_ID" --claim true)"
ACTION_TWO="$(jq -r '.actions[0].action_id // empty' <<<"$PENDING_TWO")"
test -n "$ACTION_TWO"
RESULT_TWO="$(pnpm --filter @vab/mcp exec tsx src/cli.ts result --action "$ACTION_TWO" --ok true --message "Turn 2 complete")"
test "$(jq -r '.status // empty' <<<"$RESULT_TWO")" = "done"

FINAL="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" "$API/v1/sessions/$SESSION_ID")"
test "$(jq -r '.session_id // empty' <<<"$FINAL")" = "$SESSION_ID"
test "$(jq -r '.chat_id // empty' <<<"$FINAL")" = "$CHAT_ID"
test "$(jq -r '.state // empty' <<<"$FINAL")" = "running"
printf 'canonical Codex multi-turn smoke passed: session=%s chat=%s events=%s,%s actions=%s,%s state=running backend=rust\n' "$SESSION_ID" "$CHAT_ID" "$EVENT_ONE_ID" "$EVENT_TWO_ID" "$ACTION_ONE" "$ACTION_TWO"
