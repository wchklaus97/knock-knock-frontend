#!/usr/bin/env bash
# Wait for the human phone decision, then complete the agent half of sign-off.
# Set PHYSICAL_SESSION_ID to watch an already-emitted session; otherwise this
# starts a fresh physical sign-off first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WAIT_SECONDS="${PHONE_WAIT_SECONDS:-300}"

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "PHONE_WAIT_SECONDS must be a non-negative integer." >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh" >/dev/null

if [[ -n "${PHYSICAL_SESSION_ID:-}" ]]; then
  SESSION_ID="$PHYSICAL_SESSION_ID"
else
  SIGNOFF_OUTPUT="$(cd "$ROOT" && pnpm signoff:phone)"
  printf '%s\n' "$SIGNOFF_OUTPUT"
  SESSION_ID="$(printf '%s\n' "$SIGNOFF_OUTPUT" | sed -n 's/^session=//p' | tail -n 1)"
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "Could not determine the physical sign-off session id." >&2
  exit 2
fi

echo "Watching physical session $SESSION_ID for up to ${WAIT_SECONDS}s."
deadline=$((SECONDS + WAIT_SECONDS))

while (( SECONDS <= deadline )); do
  SESSION_JSON=""
  if SESSION_JSON="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" \
    "$BRIDGE_API_URL/v1/sessions/$SESSION_ID" 2>/dev/null)"; then
    state="$(echo "$SESSION_JSON" | jq -r '.state')"
    if [[ "$state" == "queued" || "$state" == "claimed" ]]; then
      PENDING_JSON="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" \
        "$BRIDGE_API_URL/v1/sessions/$SESSION_ID/actions/pending?claim=true")"
      ACTION_ID="$(echo "$PENDING_JSON" | jq -r '.actions[0].action_id // empty')"
      if [[ -n "$ACTION_ID" ]]; then
        CANCELLED="$(echo "$PENDING_JSON" | jq -r '.actions[0].cancelled_by_user // false')"
        if [[ "$CANCELLED" == "true" ]]; then
          OK=false
          MESSAGE="User cancelled this action on the phone."
        else
          OK=true
          MESSAGE="Physical sign-off completed."
        fi
        RESULT="$(curl -sf -X POST "$BRIDGE_API_URL/v1/actions/$ACTION_ID/result" \
          -H "X-Agent-Key: $BRIDGE_AGENT_KEY" \
          -H 'content-type: application/json' \
          -d "$(jq -nc --argjson ok "$OK" --arg message "$MESSAGE" '{ok:$ok,message:$message}')")"
        FINAL_SESSION="$(curl -sf -H "X-Agent-Key: $BRIDGE_AGENT_KEY" \
          "$BRIDGE_API_URL/v1/sessions/$SESSION_ID")"
        echo "$RESULT" | jq '{action_id,status,result,cancelled_by_user}'
        echo "$FINAL_SESSION" | jq '{session_id,state,progress_status,summary_text}'
        exit 0
      fi
    elif [[ "$state" == "expired" || "$state" == "closed" || "$state" == "failed" ]]; then
      echo "$SESSION_JSON" | jq '{session_id,state,summary_text}'
      exit 1
    fi
  fi
  sleep 2
done

echo "Timed out waiting for a phone decision on $SESSION_ID." >&2
exit 2
