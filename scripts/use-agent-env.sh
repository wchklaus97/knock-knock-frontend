#!/usr/bin/env bash
# Usage (zsh or bash): source scripts/use-agent-env.sh
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _VAB_ENV_SRC="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _VAB_ENV_SRC="${(%):-%x}"
else
  _VAB_ENV_SRC="$0"
fi
ROOT="$(cd "$(dirname "$_VAB_ENV_SRC")/.." && pwd)"
unset _VAB_ENV_SRC
ENV_FILE="$ROOT/.env.agent"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  return 1 2>/dev/null || exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
echo "Loaded BRIDGE_API_URL=$BRIDGE_API_URL"
echo "Loaded BRIDGE_AGENT_KEY=${BRIDGE_AGENT_KEY:0:8}…"
