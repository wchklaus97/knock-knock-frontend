#!/usr/bin/env bash
# Secure stdio MCP entry. Keep credential material out of every bootstrap child.
unset BRIDGE_AGENT_KEY || true
unset KNOCK_KNOCK_AGENT_KEY || true
set -euo pipefail

repository_root() {
  local script_directory
  script_directory="$(cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  cd -P -- "$script_directory/.." && pwd -P
}

owned_file_metadata() {
  local candidate="$1"
  local metadata owner mode current_uid
  metadata="$(/usr/bin/stat -f '%u %Lp' "$candidate")" || return 1
  read -r owner mode <<< "$metadata"
  [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  current_uid="$(/usr/bin/id -u)" || return 1
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
}

canonical_owned_file() {
  local candidate="$1"
  local require_executable="${2:-false}"
  [[ "$candidate" == /* ]] || return 1
  [[ "$candidate" != *:* && "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || return 1

  local candidate_directory link_target
  local link_hops=0
  while [[ -L "$candidate" ]]; do
    ((link_hops += 1))
    ((link_hops <= 16)) || return 1
    link_target="$(/usr/bin/readlink "$candidate")" || return 1
    [[ "$link_target" != *$'\n'* && "$link_target" != *$'\r'* ]] || return 1
    if [[ "$link_target" == /* ]]; then
      candidate="$link_target"
    else
      candidate="$(/usr/bin/dirname -- "$candidate")/$link_target"
    fi
    candidate_directory="$(cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P)" || return 1
    candidate="$candidate_directory/${candidate##*/}"
  done

  candidate_directory="$(cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P)" || return 1
  candidate="$candidate_directory/${candidate##*/}"
  [[ -f "$candidate" ]] || return 1
  if [[ "$require_executable" == true ]]; then
    [[ -x "$candidate" ]] || return 1
  fi
  owned_file_metadata "$candidate" || return 1
  printf '%s\n' "$candidate"
}

validated_repo_file() {
  local candidate="$1"
  [[ "$candidate" == /* && -f "$candidate" && ! -L "$candidate" ]] || return 1
  owned_file_metadata "$candidate" || return 1
  printf '%s\n' "$candidate"
}

resolved_node_executable() {
  local candidate resolved
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if resolved="$(canonical_owned_file "$candidate" true 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  candidate="$(type -P -- node)" || return 1
  canonical_owned_file "$candidate" true
}

resolved_tsx_file() {
  local root="$1"
  local candidate resolved
  for candidate in \
    "$root/apps/mcp/node_modules/.bin/tsx" \
    "$root/node_modules/.bin/tsx"; do
    if resolved="$(canonical_owned_file "$candidate" false 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

executable_directory() {
  cd -P -- "$(/usr/bin/dirname -- "$1")" && pwd -P
}

main() {
  local root
  root="$(repository_root)"
  local build_script index_source
  build_script="$(validated_repo_file "$root/apps/mcp/scripts/build-macos-deny-attach.mjs")" || {
    echo "MCP wrapper refused an untrusted native build script" >&2
    exit 1
  }
  index_source="$(validated_repo_file "$root/apps/mcp/src/index.ts")" || {
    echo "MCP wrapper refused an untrusted server entry" >&2
    exit 1
  }

  local node_binary tsx_file
  node_binary="$(resolved_node_executable)" || {
    echo "MCP wrapper could not resolve a trusted Node executable" >&2
    exit 1
  }
  tsx_file="$(resolved_tsx_file "$root")" || {
    echo "MCP wrapper could not resolve trusted tsx" >&2
    exit 1
  }

  local api_url="${BRIDGE_API_URL:-https://knock-knock-backend-staging.wch-klaus.workers.dev}"
  [[ "$api_url" != *$'\n'* && "$api_url" != *$'\r'* ]] || {
    echo "BRIDGE_API_URL must be a single URL" >&2
    exit 1
  }
  case "$api_url" in
    http://*|https://*) ;;
    *) echo "BRIDGE_API_URL must use http or https" >&2; exit 1 ;;
  esac
  local authority="${api_url#*://}"
  authority="${authority%%/*}"
  [[ "$authority" != *@* ]] || {
    echo "BRIDGE_API_URL must not contain credentials" >&2
    exit 1
  }

  local agent_env="${KNOCK_KNOCK_AGENT_ENV:-$root/.env.agent.staging}"
  if [[ "$agent_env" != /* ]]; then
    agent_env="$root/$agent_env"
  fi
  [[ "$agent_env" != *$'\n'* && "$agent_env" != *$'\r'* ]] || {
    echo "KNOCK_KNOCK_AGENT_ENV must be a single path" >&2
    exit 1
  }

  local node_directory tsx_directory safe_path
  node_directory="$(executable_directory "$node_binary")"
  tsx_directory="$(executable_directory "$tsx_file")"
  safe_path="$node_directory:$tsx_directory:/usr/bin:/bin:/usr/sbin:/sbin"

  local -a build_environment=(
    "PATH=$safe_path"
    "LANG=C"
    "LC_ALL=C"
    "NODE_NO_WARNINGS=1"
    "NODE_OPTIONS=--no-warnings"
  )

  cd -P -- "$root"
  if ! /usr/bin/env -i "${build_environment[@]}" "$node_binary" "$build_script"; then
    echo "MCP wrapper refused to start: native rebuild failed" >&2
    exit 1
  fi

  if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
    local native_addon="$root/apps/mcp/build/Release/macos_deny_attach.node"
    [[ -f "$native_addon" && ! -L "$native_addon" ]] || {
      echo "MCP wrapper refused to start: native addon unavailable" >&2
      exit 1
    }
    owned_file_metadata "$native_addon" || {
      echo "MCP wrapper refused to start: native addon metadata invalid" >&2
      exit 1
    }
    if ! /usr/bin/env -i "${build_environment[@]}" "$node_binary" -e '
      try {
        const addon = require(process.argv[1]);
        process.exit(
          typeof addon.denyAttach === "function" &&
          addon.denyAttach() === true ? 0 : 1
        );
      } catch {
        process.exit(1);
      }
    ' "$native_addon"; then
      echo "MCP wrapper refused to start: native verification failed" >&2
      exit 1
    fi
  fi

  local -a runtime_environment=(
    "${build_environment[@]}"
    "BRIDGE_API_URL=$api_url"
    "KNOCK_KNOCK_AGENT_ENV=$agent_env"
  )
  exec /usr/bin/env -i "${runtime_environment[@]}" \
    "$node_binary" "$tsx_file" --no-warnings "$index_source"
}

main "$@"
