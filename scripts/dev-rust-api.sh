#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BACKEND_DIR="$ROOT/../backend"
if [[ ! -f "$DEFAULT_BACKEND_DIR/wrangler.toml" && -f "$ROOT/../knock-knock/backend/wrangler.toml" ]]; then
  DEFAULT_BACKEND_DIR="$ROOT/../knock-knock/backend"
fi
BACKEND_DIR="${KNOCK_KNOCK_BACKEND_DIR:-$DEFAULT_BACKEND_DIR}"
PORT="${KNOCK_KNOCK_API_PORT:-8787}"
BIND_IP="${KNOCK_KNOCK_BIND_IP:-0.0.0.0}"

if [[ ! -f "$BACKEND_DIR/wrangler.toml" ]]; then
  printf 'Rust backend not found at %s\n' "$BACKEND_DIR" >&2
  printf 'Set KNOCK_KNOCK_BACKEND_DIR to the knock-knock/backend checkout.\n' >&2
  exit 1
fi

if ! command -v wrangler >/dev/null 2>&1; then
  printf 'wrangler is required to run the Rust Worker.\n' >&2
  exit 1
fi

cd "$BACKEND_DIR"
wrangler d1 migrations apply DB --local
exec wrangler dev --local --ip "$BIND_IP" --port "$PORT"
