#!/usr/bin/env bash
# Release-candidate smoke for auth rotation, scoped agent keys, audit history,
# and operator metrics. It uses a disposable local account and does not touch
# the user's paired agent.
set -euo pipefail

API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/knock-knock-rc.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

post_json() {
  local path="$1"
  local body="$2"
  curl -sf -X POST "$API$path" -H 'content-type: application/json' -d "$body"
}

EMAIL="rc-$(date +%s)-$RANDOM@local.test"
AUTH="$(post_json /v1/auth/register "$(jq -nc --arg email "$EMAIL" '{email:$email,password:"password123"}')")"
TOKEN="$(echo "$AUTH" | jq -r '.token')"
REFRESH="$(echo "$AUTH" | jq -r '.refresh_token')"
test -n "$TOKEN" && test "$REFRESH" != "null"

ROTATED="$(post_json /v1/auth/refresh "$(jq -nc --arg refresh_token "$REFRESH" '{refresh_token:$refresh_token}')")"
NEW_TOKEN="$(echo "$ROTATED" | jq -r '.token')"
NEW_REFRESH="$(echo "$ROTATED" | jq -r '.refresh_token')"
test -n "$NEW_TOKEN" && test "$NEW_REFRESH" != "null"

OLD_REFRESH_STATUS="$(curl -s -o "$TEMP_ROOT/old-refresh.json" -w '%{http_code}' \
  -X POST "$API/v1/auth/refresh" -H 'content-type: application/json' \
  -d "$(jq -nc --arg refresh_token "$REFRESH" '{refresh_token:$refresh_token}')")"
test "$OLD_REFRESH_STATUS" = "401"

AGENT="$(curl -sf -X POST "$API/v1/agents" -H "Authorization: Bearer $NEW_TOKEN" \
  -H 'content-type: application/json' -d '{"label":"rc-smoke","host_label":"ci"}')"
AGENT_ID="$(echo "$AGENT" | jq -r '.agent.agent_id')"
OLD_KEY="$(echo "$AGENT" | jq -r '.api_key')"
ROTATE_AGENT="$(curl -sf -X POST "$API/v1/agents/$AGENT_ID/rotate-key" \
  -H "Authorization: Bearer $NEW_TOKEN")"
NEW_KEY="$(echo "$ROTATE_AGENT" | jq -r '.api_key')"
test "$OLD_KEY" != "$NEW_KEY"

OLD_KEY_STATUS="$(curl -s -o "$TEMP_ROOT/old-agent.json" -w '%{http_code}' \
  -X POST "$API/v1/sessions" -H "X-Agent-Key: $OLD_KEY" \
  -H 'content-type: application/json' -d '{"skill_id":"deploy.result"}')"
test "$OLD_KEY_STATUS" = "401"

SESSION="$(curl -sf -X POST "$API/v1/sessions" -H "X-Agent-Key: $NEW_KEY" \
  -H 'content-type: application/json' -d '{"skill_id":"deploy.result","title":"RC smoke","idempotency_key":"rc-smoke"}')"
SESSION_ID="$(echo "$SESSION" | jq -r '.session_id')"
curl -sf -X POST "$API/v1/sessions/$SESSION_ID/events" -H "X-Agent-Key: $NEW_KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"rc-smoke-event","actions":["ack"],"summary":"RC history check"}' >/dev/null

HISTORY="$(curl -sf "$API/v1/phone/sessions/$SESSION_ID/history" -H "Authorization: Bearer $NEW_TOKEN")"
echo "$HISTORY" | jq -e '.entries | length >= 2' >/dev/null
curl -sf "$API/metrics" | grep -q 'knock_knock_api_info{runtime="cloudflare-worker",api="rust"} 1'

echo "RC security smoke passed: refresh rotation, agent-key rotation, history, metrics"
