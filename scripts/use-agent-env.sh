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
vab_preconfigured_api_url="${BRIDGE_API_URL:-${KNOCK_KNOCK_API_URL:-}}"
vab_preconfigured_agent_key="${BRIDGE_AGENT_KEY:-}"
if [[ "${vab_preconfigured_api_url}" == *staging* && -f "$ROOT/.env.agent.staging" ]]; then
  ENV_FILE="$ROOT/.env.agent.staging"
else
  ENV_FILE="$ROOT/.env.agent"
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ -z "$vab_preconfigured_api_url" || -z "$vab_preconfigured_agent_key" ]]; then
  echo "Missing $ENV_FILE (or explicit BRIDGE_API_URL and BRIDGE_AGENT_KEY)." >&2
  return 1 2>/dev/null || exit 1
fi

# Callers may provide an isolated local Worker and freshly-created test agent.
# Do not let the repository convenience file silently replace those values,
# and never keep a file key after forcing a different API host.
if [[ -n "$vab_preconfigured_api_url" ]]; then
  file_api_url="${KNOCK_KNOCK_API_URL:-${BRIDGE_API_URL:-}}"
  BRIDGE_API_URL="$vab_preconfigured_api_url"
  export BRIDGE_API_URL
  if [[ -n "$file_api_url" ]]; then
    file_is_staging=0
    req_is_staging=0
    [[ "$file_api_url" == *staging* ]] && file_is_staging=1
    [[ "$vab_preconfigured_api_url" == *staging* ]] && req_is_staging=1
    if [[ "$file_is_staging" -ne "$req_is_staging" && -z "$vab_preconfigured_agent_key" ]]; then
      echo "Refusing mixed hosts: $ENV_FILE does not match $vab_preconfigured_api_url" >&2
      unset BRIDGE_AGENT_KEY
      return 1 2>/dev/null || exit 1
    fi
  fi
fi
if [[ -n "$vab_preconfigured_agent_key" ]]; then
  BRIDGE_AGENT_KEY="$vab_preconfigured_agent_key"
  export BRIDGE_AGENT_KEY
fi
unset vab_preconfigured_api_url vab_preconfigured_agent_key
echo "Loaded BRIDGE_API_URL=$BRIDGE_API_URL"
echo "Loaded BRIDGE_AGENT_KEY=${BRIDGE_AGENT_KEY:0:8}…"
