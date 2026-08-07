#!/usr/bin/env bash
# Automated API-level MVP proof on macOS (dev push inbox = APNs stand-in).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
EMAIL="${E2E_EMAIL:-e2e-$(date +%s)@local.test}"
PASS="${E2E_PASSWORD:-password123}"

need() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
need curl
need jq

expect_status() {
  local expected="$1"
  shift
  local response status body
  response=$(curl -sS -w $'\n%{http_code}' "$@")
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != "$expected" ]]; then
    echo "FAIL: expected HTTP $expected, got $status" >&2
    echo "$body" | jq . >&2 || echo "$body" >&2
    exit 1
  fi
  printf '%s\n' "$body"
}

echo "== health =="
curl -sf "$API/health" | jq .

echo "== register =="
AUTH=$(curl -sf -X POST "$API/v1/auth/register" \
  -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
TOKEN=$(echo "$AUTH" | jq -r .token)
echo "user=$(echo "$AUTH" | jq -r .user_id)"

echo "== create agent =="
AGENT=$(curl -sf -X POST "$API/v1/agents" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"label":"e2e-agent","host_label":"mac-script"}')
KEY=$(echo "$AGENT" | jq -r .api_key)
AGENT_ID=$(echo "$AGENT" | jq -r .agent.agent_id)
echo "agent_id=$AGENT_ID"

echo "== create session =="
SES=$(curl -sf -X POST "$API/v1/sessions" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e deploy","chat_id":"chat-demo-1"}')
SID=$(echo "$SES" | jq -r .session_id)
echo "session_id=$SID"

echo "== progress (must NOT push) =="
curl -sf -X POST "$API/v1/sessions/$SID/progress" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"running","message":"tests 12/40"}' | jq '{state,progress_status,progress_message}'

PUSHES=$(curl -sf "$API/v1/dev/pushes" -H "authorization: Bearer $TOKEN")
COUNT=$(echo "$PUSHES" | jq '.pushes | length')
if [[ "$COUNT" != "0" ]]; then
  echo "FAIL N1: progress created $COUNT pushes"
  exit 1
fi
echo "OK N1: progress did not push"

echo "== N2: needs_user without actions must fail =="
N2=$(expect_status 400 -X POST "$API/v1/sessions/$SID/events" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-missing-actions-1","actions":[] }')
echo "$N2" | jq '{error,message}'
echo "OK N2: needs_user without actions rejected"

echo "== N6: empty wake has no pending actions =="
EMPTY=$(curl -sf "$API/v1/sessions/$SID/actions/pending?claim=false" -H "X-Agent-Key: $KEY")
EMPTY_COUNT=$(echo "$EMPTY" | jq '.actions | length')
[[ "$EMPTY_COUNT" == "0" ]] || { echo "FAIL N6: expected empty pending actions"; exit 1; }
echo "OK N6: empty wake has no pending actions"

echo "== N5: two sessions bind replies independently =="
SES2=$(curl -sf -X POST "$API/v1/sessions" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e binding","chat_id":"chat-demo-2"}')
SID2=$(echo "$SES2" | jq -r .session_id)
curl -sf -X POST "$API/v1/sessions/$SID2/events" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-binding-1","facts":{"service":"worker","status":"等待确认","env":"staging"},"actions":["ack"]}' \
  | jq '{pushed,session:{session_id:.session.session_id,state:.session.state}}'

REP2=$(curl -sf -X POST "$API/v1/phone/sessions/$SID2/reply" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"action_key":"ack","utterance":"已知晓"}')
echo "$REP2" | jq '{needs_confirm,action:{status:.action.status,session_id:.action.session_id},session:{session_id:.session.session_id,state:.session.state}}'
[[ "$(echo "$REP2" | jq -r .needs_confirm)" == "false" ]] || { echo "FAIL N5: ack unexpectedly required confirmation"; exit 1; }

PENDING2=$(curl -sf "$API/v1/sessions/$SID2/actions/pending?claim=false" -H "X-Agent-Key: $KEY")
[[ "$(echo "$PENDING2" | jq -r '.actions | length')" == "1" ]] || { echo "FAIL N5: session 2 action missing"; exit 1; }
[[ "$(echo "$PENDING2" | jq -r '.actions[0].session_id')" == "$SID2" ]] || { echo "FAIL N5: session 2 action bound to wrong session"; exit 1; }

PENDING1=$(curl -sf "$API/v1/sessions/$SID/actions/pending?claim=false" -H "X-Agent-Key: $KEY")
[[ "$(echo "$PENDING1" | jq -r '.actions | length')" == "0" ]] || { echo "FAIL N5: session 1 saw session 2 action"; exit 1; }

ACTION2=$(curl -sf "$API/v1/sessions/$SID2/actions/pending?claim=true" -H "X-Agent-Key: $KEY")
ACTION2_ID=$(echo "$ACTION2" | jq -r '.actions[0].action_id')
curl -sf -X POST "$API/v1/actions/$ACTION2_ID/result" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"ok":true,"message":"acknowledged"}' >/dev/null
echo "OK N5: reply stayed bound to session 2"

echo "== N4: expired action cannot be replied to =="
SES4=$(curl -sf -X POST "$API/v1/sessions" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e ttl","chat_id":"chat-demo-4"}')
SID4=$(echo "$SES4" | jq -r .session_id)
curl -sf -X POST "$API/v1/sessions/$SID4/events" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-ttl-1","facts":{"service":"api","status":"过期","env":"test"},"actions":["rollback"]}' >/dev/null
ACTION4_ID=$(SESSION_ID="$SID4" DB_PATH="$ROOT/.data/bridge.db" node --input-type=module -e '
  import { DatabaseSync } from "node:sqlite";
  const db = new DatabaseSync(process.env.DB_PATH);
  const row = db.prepare("SELECT id FROM actions WHERE session_id = ? ORDER BY created_at DESC LIMIT 1").get(process.env.SESSION_ID);
  if (!row) process.exit(1);
  console.log(row.id);
')
SESSION_ID="$SID4" ACTION_ID="$ACTION4_ID" DB_PATH="$ROOT/.data/bridge.db" node --input-type=module -e '
  import { DatabaseSync } from "node:sqlite";
  const db = new DatabaseSync(process.env.DB_PATH);
  db.prepare("UPDATE actions SET expires_at = ? WHERE id = ?").run("2000-01-01T00:00:00.000Z", process.env.ACTION_ID);
'
N4=$(expect_status 410 -X POST "$API/v1/phone/sessions/$SID4/reply" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}')
echo "$N4" | jq '{error,message}'
echo "OK N4: expired action rejected"

echo "== needs_user (must push) =="
EV=$(curl -sf -X POST "$API/v1/sessions/$SID/events" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-1","facts":{"service":"api","status":"失败","env":"prod"},"actions":["rollback","ack"]}')
echo "$EV" | jq '{pushed,summary_text,voice_script,session:{state:.session.state}}'
PUSHED=$(echo "$EV" | jq -r .pushed)
[[ "$PUSHED" == "true" ]] || { echo "FAIL: expected pushed=true"; exit 1; }

PUSHES=$(curl -sf "$API/v1/dev/pushes" -H "authorization: Bearer $TOKEN")
COUNT=$(echo "$PUSHES" | jq '.pushes | length')
[[ "$COUNT" -ge 1 ]] || { echo "FAIL: inbox empty after needs_user"; exit 1; }
echo "OK: dev inbox has $COUNT push(es)"

echo "== phone reply destructive → needs confirm =="
REP=$(curl -sf -X POST "$API/v1/phone/sessions/$SID/reply" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}')
echo "$REP" | jq '{needs_confirm,action:{status:.action.status,action_key:.action.action_key},session:.session.state}'
NEEDS=$(echo "$REP" | jq -r .needs_confirm)
AID=$(echo "$REP" | jq -r .action.action_id)
[[ "$NEEDS" == "true" ]] || { echo "FAIL N3: expected needs_confirm"; exit 1; }

PENDING=$(curl -sf "$API/v1/agents/me/actions/pending?claim=true" -H "X-Agent-Key: $KEY")
PCOUNT=$(echo "$PENDING" | jq '.actions | length')
[[ "$PCOUNT" == "0" ]] || { echo "FAIL N3: destructive claimable before confirm"; exit 1; }
echo "OK N3: not claimable before confirm"

echo "== confirm =="
curl -sf -X POST "$API/v1/phone/sessions/$SID/confirm" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"action_id\":\"$AID\",\"confirm\":true}" | jq '{action:{status:.action.status},session:.session.state}'

PENDING=$(curl -sf "$API/v1/agents/me/actions/pending?claim=true" -H "X-Agent-Key: $KEY")
echo "$PENDING" | jq .
PCOUNT=$(echo "$PENDING" | jq '.actions | length')
[[ "$PCOUNT" -ge 1 ]] || { echo "FAIL: expected claimable action after confirm"; exit 1; }
CLAIMED_ID=$(echo "$PENDING" | jq -r '.actions[0].action_id')
CLAIMED_SESSION=$(curl -sf "$API/v1/sessions/$SID" -H "X-Agent-Key: $KEY")
[[ "$(echo "$CLAIMED_SESSION" | jq -r '.state')" == "claimed" ]] || {
  echo "FAIL N3: session did not transition to claimed"
  exit 1
}

echo "== submit result =="
RESULT=$(curl -sf -X POST "$API/v1/actions/$CLAIMED_ID/result" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"ok":true,"message":"rolled back","output":{"source":"e2e"}}')
echo "$RESULT" | jq '{status,action_key,result}'
[[ "$(echo "$RESULT" | jq -r '.status')" == "done" ]] || { echo "FAIL N3: claimed action did not complete"; exit 1; }
FINISHED_SESSION=$(curl -sf "$API/v1/sessions/$SID" -H "X-Agent-Key: $KEY")
[[ "$(echo "$FINISHED_SESSION" | jq -r '.state')" == "running" ]] || {
  echo "FAIL N3: successful action did not return session to running"
  exit 1
}

RETRY=$(curl -sf -X POST "$API/v1/actions/$CLAIMED_ID/result" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"ok":true,"message":"rolled back again"}')
[[ "$(echo "$RETRY" | jq -r '.status')" == "done" ]] || { echo "FAIL: completed result was not retry-safe"; exit 1; }
echo "OK: duplicate result retry returned the stored completed action"

echo "== N7: concurrent phone reply is idempotent =="
SES7=$(curl -sf -X POST "$API/v1/sessions" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e concurrent reply","chat_id":"chat-concurrent-reply"}')
SID7=$(echo "$SES7" | jq -r .session_id)
curl -sf -X POST "$API/v1/sessions/$SID7/events" \
  -H "X-Agent-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-concurrent-reply-1","facts":{"service":"api","status":"并发","env":"test"},"actions":["rollback"]}' >/dev/null
RACE_DIR=$(mktemp -d)
curl -sS -w $'\n%{http_code}' -X POST "$API/v1/phone/sessions/$SID7/reply" \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}' >"$RACE_DIR/reply-a" &
RACE_PID_A=$!
curl -sS -w $'\n%{http_code}' -X POST "$API/v1/phone/sessions/$SID7/reply" \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}' >"$RACE_DIR/reply-b" &
RACE_PID_B=$!
wait "$RACE_PID_A"
wait "$RACE_PID_B"
RACE_STATUS_A=$(tail -n 1 "$RACE_DIR/reply-a")
RACE_STATUS_B=$(tail -n 1 "$RACE_DIR/reply-b")
[[ "$RACE_STATUS_A" == "200" && "$RACE_STATUS_B" == "200" ]] || {
  echo "FAIL N7: concurrent phone reply statuses were $RACE_STATUS_A/$RACE_STATUS_B"
  exit 1
}
RACE_ACTIONS=$(SESSION_ID="$SID7" DB_PATH="$ROOT/.data/bridge.db" node --input-type=module -e '
  import { DatabaseSync } from "node:sqlite";
  const db = new DatabaseSync(process.env.DB_PATH);
  const row = db.prepare("SELECT COUNT(*) AS count, MAX(status) AS status FROM actions WHERE session_id = ?").get(process.env.SESSION_ID);
  console.log(JSON.stringify(row));
')
[[ "$(echo "$RACE_ACTIONS" | jq -r '.count')" == "1" ]] || { echo "FAIL N7: duplicate action row created"; exit 1; }
[[ "$(echo "$RACE_ACTIONS" | jq -r '.status')" == "pending_confirm" ]] || { echo "FAIL N7: concurrent reply lost confirmation state"; exit 1; }
rm -rf "$RACE_DIR"
echo "OK N7: concurrent phone reply returned one pending confirmation"

echo "== N8: pairing code is single-use under concurrent claim =="
PAIR=$(curl -sf -X POST "$API/v1/pairing/code" \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{}')
PAIR_CODE=$(echo "$PAIR" | jq -r .code)
PAIR_DIR=$(mktemp -d)
curl -sS -w $'\n%{http_code}' -X POST "$API/v1/pairing/claim" \
  -H 'content-type: application/json' \
  -d "{\"code\":\"$PAIR_CODE\",\"label\":\"race-a\"}" >"$PAIR_DIR/claim-a" &
PAIR_PID_A=$!
curl -sS -w $'\n%{http_code}' -X POST "$API/v1/pairing/claim" \
  -H 'content-type: application/json' \
  -d "{\"code\":\"$PAIR_CODE\",\"label\":\"race-b\"}" >"$PAIR_DIR/claim-b" &
PAIR_PID_B=$!
wait "$PAIR_PID_A"
wait "$PAIR_PID_B"
PAIR_STATUS_A=$(tail -n 1 "$PAIR_DIR/claim-a")
PAIR_STATUS_B=$(tail -n 1 "$PAIR_DIR/claim-b")
if [[ ! ( ("$PAIR_STATUS_A" == "201" && "$PAIR_STATUS_B" == "409") || ("$PAIR_STATUS_A" == "409" && "$PAIR_STATUS_B" == "201") ) ]]; then
  echo "FAIL N8: concurrent pairing statuses were $PAIR_STATUS_A/$PAIR_STATUS_B"
  exit 1
fi
rm -rf "$PAIR_DIR"
echo "OK N8: pairing code produced exactly one agent"

echo "== N9: destructive cancellation returns a decision to the agent =="
SES9=$(curl -sf -X POST "${API}/v1/sessions" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e cancellation","chat_id":"chat-cancellation"}')
SID9=$(echo "${SES9}" | jq -r .session_id)
curl -sf -X POST "${API}/v1/sessions/${SID9}/events" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-cancellation-1","facts":{"service":"api","status":"取消测试","env":"test"},"actions":["rollback"]}' >/dev/null
REP9=$(curl -sf -X POST "${API}/v1/phone/sessions/${SID9}/reply" \
  -H "authorization: Bearer ${TOKEN}" \
  -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}')
AID9=$(echo "${REP9}" | jq -r .action.action_id)
CANCEL9=$(curl -sf -X POST "${API}/v1/phone/sessions/${SID9}/confirm" \
  -H "authorization: Bearer ${TOKEN}" \
  -H 'content-type: application/json' \
  -d "{\"action_id\":\"${AID9}\",\"confirm\":false}")
[[ "$(echo "${CANCEL9}" | jq -r '.session.state')" == "queued" ]] || { echo "FAIL N9: cancelled session was not queued for the agent"; exit 1; }
[[ "$(echo "${CANCEL9}" | jq -r '.action.cancelled_by_user')" == "true" ]] || { echo "FAIL N9: cancellation marker missing"; exit 1; }
CANCEL_PENDING=$(curl -sf "${API}/v1/sessions/${SID9}/actions/pending?claim=true" -H "X-Agent-Key: ${KEY}")
CANCELLED_ID=$(echo "${CANCEL_PENDING}" | jq -r '.actions[0].action_id')
[[ "${CANCELLED_ID}" == "${AID9}" ]] || { echo "FAIL N9: cancelled action did not reach agent pending queue"; exit 1; }
[[ "$(echo "${CANCEL_PENDING}" | jq -r '.actions[0].cancelled_by_user')" == "true" ]] || { echo "FAIL N9: agent pending action lost cancellation marker"; exit 1; }
CANCEL_RESULT=$(curl -sf -X POST "${API}/v1/actions/${CANCELLED_ID}/result" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"ok":false,"message":"recorded user cancellation"}')
[[ "$(echo "${CANCEL_RESULT}" | jq -r '.status')" == "failed" ]] || { echo "FAIL N9: cancellation result did not close action"; exit 1; }
[[ "$(echo "${CANCEL_RESULT}" | jq -r '.cancelled_by_user')" == "true" ]] || { echo "FAIL N9: cancellation marker lost on result"; exit 1; }
echo "OK N9: destructive cancellation returned to the agent and closed safely"

echo "== N9b: cancelling one alternative preserves the other phone action =="
SES9B=$(curl -sf -X POST "${API}/v1/sessions" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e cancellation alternatives","chat_id":"chat-cancellation-alternatives"}')
SID9B=$(echo "${SES9B}" | jq -r .session_id)
curl -sf -X POST "${API}/v1/sessions/${SID9B}/events" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-cancellation-alternatives-1","facts":{"service":"api","status":"alternative","env":"test"},"actions":["rollback","ack"]}' >/dev/null
REP9B=$(curl -sf -X POST "${API}/v1/phone/sessions/${SID9B}/reply" \
  -H "authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
  -d '{"action_key":"rollback","utterance":"回滚"}')
AID9B=$(echo "${REP9B}" | jq -r .action.action_id)
CANCEL9B=$(curl -sf -X POST "${API}/v1/phone/sessions/${SID9B}/confirm" \
  -H "authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
  -d "{\"action_id\":\"${AID9B}\",\"confirm\":false}")
if ! echo "${CANCEL9B}" | jq -e '.session.state == "needs_user" and (.session.available_actions == ["ack"])' >/dev/null; then
  echo "FAIL N9b: alternative cancellation did not preserve the remaining decision"
  echo "${CANCEL9B}" | jq '{session: {state, available_actions, progress_message}, action: {status, cancelled_by_user}}'
  exit 1
fi
REMAINING9B=$(curl -sf "${API}/v1/sessions/${SID9B}/actions/pending?claim=false" -H "X-Agent-Key: ${KEY}")
[[ "$(echo "${REMAINING9B}" | jq '.actions | length')" == "0" ]] || { echo "FAIL N9b: cancelled alternative became claimable too early"; exit 1; }
ACK9B=$(curl -sf -X POST "${API}/v1/phone/sessions/${SID9B}/reply" \
  -H "authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
  -d '{"action_key":"ack","utterance":"已知晓"}')
[[ "$(echo "${ACK9B}" | jq -r '.session.state')" == "queued" ]] || { echo "FAIL N9b: remaining action could not be selected"; exit 1; }
ACK_PENDING9B=$(curl -sf "${API}/v1/sessions/${SID9B}/actions/pending?claim=true" -H "X-Agent-Key: ${KEY}")
ACK_ID9B=$(echo "${ACK_PENDING9B}" | jq -r '.actions[0].action_id')
curl -sf -X POST "${API}/v1/actions/${ACK_ID9B}/result" \
  -H "X-Agent-Key: ${KEY}" -H 'content-type: application/json' \
  -d '{"ok":true,"message":"ack alternative"}' >/dev/null
echo "OK N9b: the phone could choose the remaining action after cancellation"

echo "== N10: duplicate event idempotency is atomic under concurrency =="
SES10=$(curl -sf -X POST "${API}/v1/sessions" \
  -H "X-Agent-Key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e event race","chat_id":"chat-event-race"}')
SID10=$(echo "${SES10}" | jq -r .session_id)
EVENT_DIR=$(mktemp -d)
curl -sS -w $'\n%{http_code}' -X POST "${API}/v1/sessions/${SID10}/events" \
  -H "X-Agent-Key: ${KEY}" -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-event-race-1","facts":{"service":"api","status":"race","env":"test"},"actions":["ack"]}' >"${EVENT_DIR}/event-a" &
EVENT_PID_A=$!
curl -sS -w $'\n%{http_code}' -X POST "${API}/v1/sessions/${SID10}/events" \
  -H "X-Agent-Key: ${KEY}" -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-event-race-1","facts":{"service":"api","status":"race","env":"test"},"actions":["ack"]}' >"${EVENT_DIR}/event-b" &
EVENT_PID_B=$!
wait "${EVENT_PID_A}"
wait "${EVENT_PID_B}"
EVENT_STATUS_A=$(tail -n 1 "${EVENT_DIR}/event-a")
EVENT_STATUS_B=$(tail -n 1 "${EVENT_DIR}/event-b")
[[ "${EVENT_STATUS_A}" == "200" && "${EVENT_STATUS_B}" == "200" ]] || {
  echo "FAIL N10: concurrent event statuses were ${EVENT_STATUS_A}/${EVENT_STATUS_B}"
  exit 1
}
EVENT_COUNT=$(SESSION_ID="${SID10}" DB_PATH="${ROOT}/.data/bridge.db" node --input-type=module -e '
  import { DatabaseSync } from "node:sqlite";
  const db = new DatabaseSync(process.env.DB_PATH);
  const row = db.prepare("SELECT COUNT(*) AS count FROM events WHERE session_id = ? AND idempotency_key = ?").get(process.env.SESSION_ID, "e2e-event-race-1");
  console.log(row.count);
')
[[ "${EVENT_COUNT}" == "1" ]] || { echo "FAIL N10: duplicate event rows were created"; exit 1; }
rm -rf "${EVENT_DIR}"
echo "OK N10: duplicate event requests converged on one stored event"

echo "== N11: stale waiting metadata never renders a dead phone action =="
SES11=$(curl -sf -X POST "${API}/v1/sessions" \
  -H "X-Agent-Key: ${KEY}" -H 'content-type: application/json' \
  -d '{"skill_id":"deploy.result","title":"e2e stale waiting state","chat_id":"chat-stale-waiting"}')
SID11=$(echo "${SES11}" | jq -r .session_id)
curl -sf -X POST "${API}/v1/sessions/${SID11}/events" \
  -H "X-Agent-Key: ${KEY}" -H 'content-type: application/json' \
  -d '{"status":"needs_user","idempotency_key":"e2e-stale-waiting-1","actions":["ack"]}' >/dev/null
SESSION_ID="${SID11}" DB_PATH="${ROOT}/.data/bridge.db" node --input-type=module -e '
  import { DatabaseSync } from "node:sqlite";
  const db = new DatabaseSync(process.env.DB_PATH);
  db.prepare("DELETE FROM actions WHERE session_id = ?").run(process.env.SESSION_ID);
'
STALE11=$(curl -sf "${API}/v1/phone/sessions" -H "authorization: Bearer ${TOKEN}" \
  | jq -c --arg sid "${SID11}" '.sessions[] | select(.session_id == $sid)')
if ! echo "${STALE11}" | jq -e '.state == "running" and (.available_actions | length) == 0' >/dev/null; then
  echo "FAIL N11: stale waiting session still exposed a dead action"
  echo "${STALE11}" | jq .
  exit 1
fi
echo "OK N11: stale waiting metadata was reconciled before phone rendering"

echo ""
echo "ALL API E2E CHECKS PASSED (N1-N11)"
echo "Next: open iOS Simulator app, sign in as $EMAIL / $PASS, verify session + Dev Push inbox."
