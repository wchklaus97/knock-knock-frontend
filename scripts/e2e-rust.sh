#!/usr/bin/env bash
# Canonical API smoke. The default e2e command must never silently exercise
# the legacy Node API; that path is retained separately as e2e:node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_BACKEND_DIR="$ROOT/../backend"
if [[ ! -f "$DEFAULT_BACKEND_DIR/wrangler.toml" && -f "$ROOT/../knock-knock/backend/wrangler.toml" ]]; then
  DEFAULT_BACKEND_DIR="$ROOT/../knock-knock/backend"
fi
BACKEND_DIR="${KNOCK_KNOCK_BACKEND_DIR:-$DEFAULT_BACKEND_DIR}"
API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"

[[ -x "$BACKEND_DIR/scripts/contract-smoke.sh" ]] || {
  echo "Rust contract smoke not found at $BACKEND_DIR/scripts/contract-smoke.sh" >&2
  exit 1
}

HEALTH="$(curl -sf "$API/health")"
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "Default e2e requires the Rust Worker at $API" >&2
  echo "$HEALTH" | jq '{ok,api,runtime,version}' >&2
  exit 1
}

BASE_URL="$API" "$BACKEND_DIR/scripts/contract-smoke.sh"
