#!/usr/bin/env bash
# Keep the paired agent listening without claiming asks.
# Never source a local key and then point it at Staging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAGING_URL="${KNOCK_KNOCK_API_URL:-${BRIDGE_API_URL:-https://knock-knock-backend-staging.wch-klaus.workers.dev}}"
ENV_FILE=""
if [[ "$STAGING_URL" == *staging* ]]; then
  ENV_FILE="$ROOT/.env.agent.staging"
elif [[ -f "$ROOT/.env.agent" ]]; then
  ENV_FILE="$ROOT/.env.agent"
fi
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  echo "Missing bound agent env for $STAGING_URL (expected .env.agent.staging on Staging)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
FILE_URL="${KNOCK_KNOCK_API_URL:-${BRIDGE_API_URL:-}}"
if [[ "$STAGING_URL" == *staging* && "$FILE_URL" != *staging* ]]; then
  echo "Refusing to listen: $ENV_FILE is not bound to Staging." >&2
  exit 1
fi
export BRIDGE_API_URL="${KNOCK_KNOCK_API_URL:-${BRIDGE_API_URL:-$STAGING_URL}}"
exec pnpm --filter @vab/mcp exec tsx src/cli.ts listen
