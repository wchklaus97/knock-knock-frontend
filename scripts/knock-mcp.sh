#!/usr/bin/env bash
# Cursor stdio MCP entry. No network before the server handshake.
set -euo pipefail
WT="/Users/klaus_mac/Projects/01-Active/voice-agent-bridge/.worktrees/structured-memory-ios-v2"
MAIN="/Users/klaus_mac/Projects/01-Active/voice-agent-bridge"
TSX="$MAIN/apps/mcp/node_modules/.bin/tsx"
if [[ ! -x "$TSX" ]]; then
  echo "tsx is missing at $TSX" >&2
  exit 1
fi
export NODE_NO_WARNINGS=1
export NODE_OPTIONS="${NODE_OPTIONS:-} --no-warnings"
export NODE_PATH="$WT/apps/mcp/node_modules:$WT/node_modules:${NODE_PATH:-}"
# Never inherit a leftover local key into Staging.
unset BRIDGE_AGENT_KEY || true
unset KNOCK_KNOCK_AGENT_KEY || true
export BRIDGE_API_URL="${BRIDGE_API_URL:-https://knock-knock-backend-staging.wch-klaus.workers.dev}"
export KNOCK_KNOCK_AGENT_ENV="${KNOCK_KNOCK_AGENT_ENV:-$WT/.env.agent.staging}"
cd "$WT"
exec "$TSX" --no-warnings "$WT/apps/mcp/src/index.ts"
