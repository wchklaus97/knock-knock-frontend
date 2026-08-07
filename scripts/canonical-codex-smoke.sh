#!/usr/bin/env bash
# Canonical host smoke for Codex: use the same MCP/CLI contract that Codex
# loads, complete a safe phone decision, and verify the exact session result.
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
  echo "Canonical Codex smoke requires the Rust Worker at $API" >&2
  echo "$HEALTH" | jq '{ok,api,runtime,version}' >&2
  exit 1
}

RUN_TAG="codex-canonical-$(date +%s)-$RANDOM"
SESSION_JSON="$(cd "$ROOT" && pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --skill deploy.result \
  --title "Codex canonical smoke" \
  --chat "$RUN_TAG")"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$SESSION_JSON")"
test -n "$SESSION_ID"

cd "$ROOT"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" --status running --message "Codex host smoke" >/dev/null
EVENT_JSON="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" --status needs_user --idemp "$RUN_TAG-event" \
  --service codex --env test --fact_status "Canonical host check" --actions ack)"
test "$(jq -r '.pushed // false' <<<"$EVENT_JSON")" = "true"

EMAIL="${E2E_EMAIL:-e2e-1785931570@local.test}"
PASSWORD="${E2E_PASSWORD:-password123}"
AUTH="$(curl -sf -X POST "$API/v1/auth/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg email "$EMAIL" --arg password "$PASSWORD" '{email:$email,password:$password}')")"
USER_TOKEN="$(jq -r '.token // empty' <<<"$AUTH")"
test -n "$USER_TOKEN"

REPLY="$(curl -sf -X POST "$API/v1/phone/sessions/$SESSION_ID/reply" \
  -H "Authorization: Bearer $USER_TOKEN" -H 'content-type: application/json' \
  -d '{"action_key":"ack","utterance":"确认"}')"
test "$(jq -r '.needs_confirm // false' <<<"$REPLY")" = "false"

PENDING="$(pnpm --filter @vab/mcp exec tsx src/cli.ts pending --session "$SESSION_ID" --claim true)"
ACTION_ID="$(jq -r '.actions[0].action_id // empty' <<<"$PENDING")"
test -n "$ACTION_ID"
RESULT="$(pnpm --filter @vab/mcp exec tsx src/cli.ts result --action "$ACTION_ID" --ok true --message "Codex canonical smoke passed")"
test "$(jq -r '.status // empty' <<<"$RESULT")" = "done"

FINAL="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" "$API/v1/sessions/$SESSION_ID")"
test "$(jq -r '.state // empty' <<<"$FINAL")" = "running"
printf 'canonical Codex smoke passed: session=%s state=%s backend=rust\n' \
  "$SESSION_ID" "$(jq -r '.state' <<<"$FINAL")"
