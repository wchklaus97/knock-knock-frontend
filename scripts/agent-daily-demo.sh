#!/usr/bin/env bash
# Daily smoke: session → progress → needs_user (leave confirm to the phone).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh"

curl -sf "${BRIDGE_API_URL}/health" >/dev/null

SID=$(pnpm --filter @vab/mcp exec tsx src/cli.ts session \
  --skill deploy.result \
  --title "daily-$(date +%H%M)" | jq -r .session_id)
echo "session=$SID"

pnpm --filter @vab/mcp exec tsx src/cli.ts progress \
  --session "$SID" --status running --message "working…" >/dev/null

pnpm --filter @vab/mcp exec tsx src/cli.ts event \
  --session "$SID" \
  --status needs_user \
  --idemp "daily-$(date +%s)" \
  --service api \
  --fact_status "需要确认" \
  --env local \
  --actions rollback,ack | jq '{pushed,summary_text,state:.session.state}'

echo "Confirm on phone (same user as agent key), then: pnpm --filter @vab/mcp exec tsx src/cli.ts pending"
