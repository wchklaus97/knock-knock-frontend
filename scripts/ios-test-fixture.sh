#!/usr/bin/env bash
# Create a fresh, self-contained needs_user decision for the iOS UI suite.
# The fixture uses the canonical Rust Worker and the same agent credential that
# the Codex MCP host uses; it never relies on retained pushes from an old run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh" >/dev/null

HEALTH="$(curl -sf "$BRIDGE_API_URL/health")"
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "iOS fixture requires the Rust Worker at $BRIDGE_API_URL" >&2
  echo "$HEALTH" | jq '{ok,api,runtime,version}' >&2
  exit 1
}

RUN_TAG="${IOS_FIXTURE_TAG:-ios-ui-$(date +%s)-$RANDOM}"
TITLE="iOS UI fixture $RUN_TAG"

SESSION_JSON="$(cd "$ROOT" && pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --skill deploy.result \
  --title "$TITLE" \
  --chat "$RUN_TAG")"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$SESSION_JSON")"
test -n "$SESSION_ID"

cd "$ROOT"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SESSION_ID" \
  --status running \
  --message "Preparing deterministic iOS decision fixture" >/dev/null

EVENT_JSON="$(pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SESSION_ID" \
  --status needs_user \
  --idemp "$RUN_TAG-event" \
  --service ios-ui \
  --env test \
  --fact_status "Deterministic UI fixture" \
  --actions rollback,ack)"

test "$(jq -r '.pushed // false' <<<"$EVENT_JSON")" = "true" || {
  echo "iOS fixture did not create a pushable needs_user event" >&2
  echo "$EVENT_JSON" | jq '{pushed,summary_text,state:.session.state}' >&2
  exit 1
}

printf 'session=%s\nfixture=%s\n' "$SESSION_ID" "$RUN_TAG"
