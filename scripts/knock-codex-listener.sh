#!/usr/bin/env bash
# Persistent read-only wake observer. Claiming happens only inside get_user_asks.

repository_root() {
  local script_directory
  script_directory="$(cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  cd -P -- "$script_directory/.." && pwd -P
}

normalize_listener_takeover() {
  case "${KNOCK_KNOCK_LISTENER_TAKEOVER:-}" in
    true)
      export KNOCK_KNOCK_LISTENER_TAKEOVER=true
      ;;
    ""|false)
      unset KNOCK_KNOCK_LISTENER_TAKEOVER || true
      ;;
    *)
      echo "KNOCK_KNOCK_LISTENER_TAKEOVER must be true or false" >&2
      return 1
      ;;
  esac
}

normalized_agent_env() {
  local root="$1"
  local candidate="${KNOCK_KNOCK_AGENT_ENV:-$root/.env.agent.staging}"
  if [[ "$candidate" != /* ]]; then
    candidate="$root/$candidate"
  fi
  [[ "$candidate" == *$'\n'* || "$candidate" == *$'\r'* ]] && return 1
  printf '%s\n' "$candidate"
}

canonical_executable() {
  local candidate="$1"
  [[ "$candidate" == *:* || "$candidate" == *$'\n'* || "$candidate" == *$'\r'* ]] && return 1
  if [[ "$candidate" != /* ]]; then
    candidate="$PWD/$candidate"
  fi

  local candidate_directory link_target
  local link_hops=0
  while [[ -L "$candidate" ]]; do
    ((link_hops += 1))
    ((link_hops <= 16)) || return 1
    link_target="$(/usr/bin/readlink "$candidate")" || return 1
    [[ "$link_target" == *$'\n'* || "$link_target" == *$'\r'* ]] && return 1
    if [[ "$link_target" == /* ]]; then
      candidate="$link_target"
    else
      candidate="$(/usr/bin/dirname "$candidate")/$link_target"
    fi
    candidate_directory="$(cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P)" || return 1
    candidate="$candidate_directory/${candidate##*/}"
  done

  candidate_directory="$(cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P)" || return 1
  candidate="$candidate_directory/${candidate##*/}"
  [[ -f "$candidate" && -x "$candidate" ]] || return 1

  local metadata owner mode current_uid
  metadata="$(/usr/bin/stat -f '%u %Lp' "$candidate")" || return 1
  read -r owner mode <<< "$metadata"
  [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  current_uid="$(/usr/bin/id -u)" || return 1
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1

  printf '%s\n' "$candidate"
}

resolved_executable() {
  local candidate
  candidate="$(type -P -- "$1")" || return 1
  canonical_executable "$candidate"
}

resolved_node_executable() {
  local candidate resolved
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if resolved="$(canonical_executable "$candidate" 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  resolved_executable node
}

executable_directory() {
  cd -P -- "$(/usr/bin/dirname -- "$1")" && pwd -P
}

main() {
  set -euo pipefail
  normalize_listener_takeover
  local takeover="${KNOCK_KNOCK_LISTENER_TAKEOVER:-false}"

  local root
  root="$(repository_root)"
  if [[ ! -f "$root/package.json" || ! -f "$root/apps/mcp/package.json" ]]; then
    echo "listener launcher must run from a Voice Agent Bridge checkout" >&2
    exit 1
  fi

  local thread_variable thread_value
  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    thread_variable="CODEX_THREAD_ID"
    thread_value="$CODEX_THREAD_ID"
  elif [[ -n "${KNOCK_KNOCK_CHAT_ID:-}" ]]; then
    thread_variable="KNOCK_KNOCK_CHAT_ID"
    thread_value="$KNOCK_KNOCK_CHAT_ID"
  else
    echo "CODEX_THREAD_ID or KNOCK_KNOCK_CHAT_ID is required" >&2
    exit 1
  fi

  local codex_binary node_binary
  codex_binary="$(resolved_executable codex)" || {
    echo "codex CLI is missing" >&2
    exit 1
  }
  node_binary="$(resolved_node_executable)" || {
    echo "node is required" >&2
    exit 1
  }

  local package_binary
  local -a package_runner
  if package_binary="$(resolved_executable pnpm)"; then
    package_runner=("$package_binary")
  elif package_binary="$(resolved_executable corepack)"; then
    package_runner=("$package_binary" pnpm)
  else
    echo "pnpm or corepack is required" >&2
    exit 1
  fi

  local node_directory package_directory codex_directory safe_path
  node_directory="$(executable_directory "$node_binary")"
  package_directory="$(executable_directory "$package_binary")"
  codex_directory="$(executable_directory "$codex_binary")"
  safe_path="$node_directory:$package_directory:$codex_directory:/usr/bin:/bin:/usr/sbin:/sbin"

  local listener_home="${HOME:-$root}"
  if [[ "$listener_home" != /* || "$listener_home" == *$'\n'* || "$listener_home" == *$'\r'* ]]; then
    echo "HOME must be an absolute path" >&2
    exit 1
  fi

  local agent_env
  agent_env="$(normalized_agent_env "$root")" || {
    echo "KNOCK_KNOCK_AGENT_ENV must be a single path" >&2
    exit 1
  }
  local bridge_api_url="${BRIDGE_API_URL:-https://knock-knock-backend-staging.wch-klaus.workers.dev}"
  if [[ "$bridge_api_url" == *$'\n'* || "$bridge_api_url" == *$'\r'* ]]; then
    echo "BRIDGE_API_URL must be a single URL" >&2
    exit 1
  fi

  local listener_instance_id="${KNOCK_KNOCK_LISTENER_INSTANCE_ID:-}"
  if [[ -z "$listener_instance_id" ]]; then
    if [[ -x /usr/bin/uuidgen ]]; then
      listener_instance_id="listener_$(/usr/bin/uuidgen)"
    else
      listener_instance_id="listener_${PPID}_${RANDOM}_$(/bin/date +%s)"
    fi
  fi

  local -a build_environment
  build_environment=(
    "HOME=$listener_home"
    "PATH=$safe_path"
    "LANG=C"
    "LC_ALL=C"
    "NODE_NO_WARNINGS=1"
    "NODE_OPTIONS=--no-warnings"
  )

  local build_script="$root/apps/mcp/scripts/build-macos-deny-attach.mjs"
  local native_addon="$root/apps/mcp/build/Release/macos_deny_attach.node"
  if [[ ! -f "$build_script" || -L "$build_script" ]]; then
    echo "macOS anti-attach build script is unavailable" >&2
    exit 1
  fi

  cd -P -- "$root"
  if ! /usr/bin/env -i "${build_environment[@]}" "$node_binary" "$build_script"; then
    echo "listener refused to start: macOS anti-attach rebuild failed" >&2
    exit 1
  fi
  if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
    if [[ ! -f "$native_addon" || -L "$native_addon" ]]; then
      echo "listener refused to start: macOS anti-attach addon is unavailable" >&2
      exit 1
    fi
    if ! /usr/bin/env -i "${build_environment[@]}" "$node_binary" -e '
      const addonPath = process.argv[1];
      try {
        const metadata = require("node:fs").lstatSync(addonPath);
        const addon = require(addonPath);
        if (!metadata.isFile() || metadata.isSymbolicLink()) process.exit(1);
        if ((metadata.mode & 0o022) !== 0 || typeof addon.denyAttach !== "function") process.exit(1);
        process.exit(addon.denyAttach() === true ? 0 : 1);
      } catch {
        process.exit(1);
      }
    ' "$native_addon"; then
      echo "listener refused to start: macOS anti-attach verification failed" >&2
      exit 1
    fi
  fi

  local -a runtime_environment=(
    "${build_environment[@]}"
    "BRIDGE_API_URL=$bridge_api_url"
    "KNOCK_KNOCK_AGENT_ENV=$agent_env"
    "KNOCK_KNOCK_LISTENER_INSTANCE_ID=$listener_instance_id"
    "$thread_variable=$thread_value"
  )
  if [[ "$takeover" == true ]]; then
    runtime_environment+=("KNOCK_KNOCK_LISTENER_TAKEOVER=true")
  fi
  if [[ -n "${VAB_CAPTURE:-}" ]]; then
    if [[ "$VAB_CAPTURE" != /* || "$VAB_CAPTURE" == *$'\n'* || "$VAB_CAPTURE" == *$'\r'* ]]; then
      echo "VAB_CAPTURE must be an absolute path" >&2
      exit 1
    fi
    runtime_environment+=("VAB_CAPTURE=$VAB_CAPTURE")
  fi

  exec /usr/bin/env -i "${runtime_environment[@]}" \
    "${package_runner[@]}" \
    --dir "$root" \
    --filter @vab/mcp \
    exec tsx --no-warnings src/codex-listener.ts
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
