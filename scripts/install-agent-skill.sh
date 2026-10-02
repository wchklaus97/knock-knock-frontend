#!/usr/bin/env bash
# Install the shared Knock Knock skill and secure MCP wrapper configuration.
set -euo pipefail

script_directory="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -P -- "$script_directory/.." && pwd -P)"
TARGET="all"
API_URL="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
PAPERCLIP_ROOT="${PAPERCLIP_HOME:-$PWD/.paperclip}"
PAPERCLIP_SKILLS_DIR="${PAPERCLIP_SKILLS_DIR:-$PAPERCLIP_ROOT/skills}"
PAPERCLIP_CONFIG_DIR="${PAPERCLIP_CONFIG_DIR:-$PAPERCLIP_ROOT}"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/install-agent-skill.sh [options]

Options:
  --target all|codex|cursor|paperclip   Hosts to install (default: all)
  --api-url URL                         Bridge URL used by the MCP snippet
  --repo PATH                           Absolute repository path for host configs
  --paperclip-home PATH                 Paperclip project/config root
  --paperclip-skills-dir PATH           Exact Paperclip skills directory
  --paperclip-config-dir PATH           Exact Paperclip config directory
  -h, --help                            Show this help

The installer writes private host snippets that invoke scripts/knock-mcp.sh.
It does not overwrite global Codex, Cursor, or Paperclip configuration files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --api-url)
      API_URL="${2:-}"
      shift 2
      ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "--repo requires a path" >&2; exit 2; }
      ROOT="$(cd -P -- "$2" && pwd -P)"
      shift 2
      ;;
    --paperclip-home)
      mkdir -p "${2:-}"
      PAPERCLIP_ROOT="$(cd "${2:-}" && pwd)"
      PAPERCLIP_SKILLS_DIR="${PAPERCLIP_ROOT}/skills"
      PAPERCLIP_CONFIG_DIR="${PAPERCLIP_ROOT}"
      shift 2
      ;;
    --paperclip-skills-dir)
      PAPERCLIP_SKILLS_DIR="${2:-}"
      shift 2
      ;;
    --paperclip-config-dir)
      PAPERCLIP_CONFIG_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$TARGET" in
  all|codex|cursor|paperclip) ;;
  *) echo "--target must be all, codex, cursor, or paperclip" >&2; exit 2 ;;
esac

single_line() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

file_metadata() {
  local candidate="$1"
  if stat -f '%u %Lp' "$candidate" 2>/dev/null; then
    return 0
  fi
  stat -c '%u %a' "$candidate" 2>/dev/null
}

validate_wrapper() {
  local expected="$ROOT/scripts/knock-mcp.sh"
  local wrapper_directory
  wrapper_directory="$(cd -P -- "$(dirname -- "$expected")" && pwd -P)" || return 1
  MCP_WRAPPER="$wrapper_directory/knock-mcp.sh"
  [[ "$MCP_WRAPPER" == "$expected" ]] || return 1
  [[ "$MCP_WRAPPER" == /* && -f "$MCP_WRAPPER" && -x "$MCP_WRAPPER" ]] || return 1
  [[ ! -L "$MCP_WRAPPER" ]] || return 1

  local metadata owner mode current_uid
  metadata="$(file_metadata "$MCP_WRAPPER")" || return 1
  read -r owner mode <<< "$metadata"
  [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  current_uid="$(id -u)" || return 1
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

single_line "$ROOT" && single_line "$API_URL" || {
  echo "Repository path and API URL must be single-line values" >&2
  exit 1
}
case "$API_URL" in
  http://*|https://*) ;;
  *) echo "--api-url must use http or https" >&2; exit 2 ;;
esac

AGENT_ENV_PATH="${KNOCK_KNOCK_AGENT_ENV:-$ROOT/.env.agent}"
if [[ "$AGENT_ENV_PATH" != /* ]]; then
  AGENT_ENV_PATH="$ROOT/$AGENT_ENV_PATH"
fi
single_line "$AGENT_ENV_PATH" || {
  echo "KNOCK_KNOCK_AGENT_ENV must be a single path" >&2
  exit 1
}

validate_wrapper || {
  echo "Secure MCP wrapper validation failed" >&2
  exit 1
}

SKILL_SOURCE="$ROOT/skills/knock-knock/SKILL.md"
CURSOR_SOURCE="$ROOT/skills/knock-knock/cursor-rule.mdc"
[[ -f "$SKILL_SOURCE" && -f "$CURSOR_SOURCE" ]] || {
  echo "Knock Knock skill sources were not found under $ROOT" >&2
  exit 1
}

write_file() {
  local source="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
  chmod 0644 "$destination"
}

write_mcp_json() {
  local destination="$1"
  mkdir -p "$(dirname "$destination")"
  local wrapper_json root_json api_json env_json
  wrapper_json="$(json_escape "$MCP_WRAPPER")"
  root_json="$(json_escape "$ROOT")"
  api_json="$(json_escape "$API_URL")"
  env_json="$(json_escape "$AGENT_ENV_PATH")"
  cat > "$destination" <<EOF
{
  "mcpServers": {
    "voice-agent-bridge": {
      "command": "$wrapper_json",
      "args": [],
      "cwd": "$root_json",
      "env": {
        "BRIDGE_API_URL": "$api_json",
        "KNOCK_KNOCK_AGENT_ENV": "$env_json"
      }
    }
  }
}
EOF
  chmod 0644 "$destination"
}

write_codex_toml() {
  local destination="$1"
  mkdir -p "$(dirname "$destination")"
  local wrapper_toml root_toml api_toml env_toml
  wrapper_toml="$(toml_escape "$MCP_WRAPPER")"
  root_toml="$(toml_escape "$ROOT")"
  api_toml="$(toml_escape "$API_URL")"
  env_toml="$(toml_escape "$AGENT_ENV_PATH")"
  cat > "$destination" <<EOF
[mcp_servers.voice-agent-bridge]
command = "$wrapper_toml"
args = []
cwd = "$root_toml"

[mcp_servers.voice-agent-bridge.env]
BRIDGE_API_URL = "$api_toml"
KNOCK_KNOCK_AGENT_ENV = "$env_toml"
EOF
  chmod 0644 "$destination"
}

if [[ "$TARGET" == "all" || "$TARGET" == "codex" ]]; then
  CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}"
  CODEX_SKILL_DIR="$CODEX_ROOT/skills/knock-knock"
  write_file "$SKILL_SOURCE" "$CODEX_SKILL_DIR/SKILL.md"
  write_codex_toml "$CODEX_SKILL_DIR/voice-agent-bridge.toml"
  echo "Installed Codex skill: $CODEX_SKILL_DIR/SKILL.md"
  echo "Codex MCP snippet: $CODEX_SKILL_DIR/voice-agent-bridge.toml"
fi

if [[ "$TARGET" == "all" || "$TARGET" == "cursor" ]]; then
  CURSOR_ROOT="${CURSOR_HOME:-$HOME/.cursor}"
  write_file "$CURSOR_SOURCE" "$CURSOR_ROOT/rules/knock-knock.mdc"
  write_mcp_json "$CURSOR_ROOT/knock-knock-mcp.json"
  echo "Installed Cursor rule: $CURSOR_ROOT/rules/knock-knock.mdc"
  echo "Cursor MCP snippet: $CURSOR_ROOT/knock-knock-mcp.json"
fi

if [[ "$TARGET" == "all" || "$TARGET" == "paperclip" ]]; then
  PAPERCLIP_SKILL_DIR="$PAPERCLIP_SKILLS_DIR/knock-knock"
  write_file "$SKILL_SOURCE" "$PAPERCLIP_SKILL_DIR/SKILL.md"
  write_mcp_json "$PAPERCLIP_CONFIG_DIR/knock-knock-mcp.json"
  echo "Installed Paperclip skill: $PAPERCLIP_SKILL_DIR/SKILL.md"
  echo "Paperclip MCP snippet: $PAPERCLIP_CONFIG_DIR/knock-knock-mcp.json"
fi

cat <<EOF

Next:
  1. Open Knock Knock → Settings → Connect an Agent → Generate pairing code.
  2. Claim it once:
       pnpm --filter @vab/mcp exec tsx src/cli.ts pair --code CODE --label agent --write-env .env.agent
  3. Merge the generated host snippet into the selected agent host and restart it.

The agent key stays in .env.agent (mode 0600) and is never written by this
installer into a shared host configuration. Every generated MCP entry invokes:
  $MCP_WRAPPER
EOF
