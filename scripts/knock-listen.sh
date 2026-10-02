#!/usr/bin/env bash
# Keep the paired agent listening without claiming asks.
# Never execute a credential file or point a key at a different API origin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CANONICAL_STAGING_URL="https://knock-knock-backend-staging.wch-klaus.workers.dev"
CANONICAL_PRODUCTION_URL="https://knock-knock-backend-production.wch-klaus.workers.dev"
REQUESTED_URL="${KNOCK_KNOCK_API_URL:-${BRIDGE_API_URL:-$CANONICAL_STAGING_URL}}"
while [[ "$REQUESTED_URL" == */ ]]; do REQUESTED_URL="${REQUESTED_URL%/}"; done

if [[ -n "${KNOCK_KNOCK_AGENT_ENV:-}" ]]; then
  ENV_FILE="$KNOCK_KNOCK_AGENT_ENV"
elif [[ "$REQUESTED_URL" == "$CANONICAL_STAGING_URL" ]]; then
  ENV_FILE="$ROOT/.env.agent.staging"
elif [[ "$REQUESTED_URL" == "$CANONICAL_PRODUCTION_URL" ]]; then
  ENV_FILE="$ROOT/.env.agent.production"
else
  ENV_FILE="$ROOT/.env.agent"
fi

export KNOCK_KNOCK_AGENT_ENV="$ENV_FILE"
export KNOCK_KNOCK_API_URL="$REQUESTED_URL"
export BRIDGE_API_URL="$REQUESTED_URL"
unset BRIDGE_AGENT_KEY || true
unset KNOCK_KNOCK_AGENT_KEY || true
# client.ts performs O_NOFOLLOW open, fstat validation, parsing, and origin binding.
exec pnpm --filter @vab/mcp exec tsx src/cli.ts listen
