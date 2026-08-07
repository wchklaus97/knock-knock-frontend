#!/usr/bin/env bash
# Install the shared Knock Knock skill into Codex, Cursor, and/or Paperclip.
# The command writes isolated snippets and never overwrites a host's main
# configuration file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

The installer writes private host snippets but does not overwrite global
Codex, Cursor, or Paperclip configuration files.
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
      ROOT="$(cd "${2:-}" && pwd)"
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
  cat > "$destination" <<EOF
{
  "mcpServers": {
    "voice-agent-bridge": {
      "command": "pnpm",
      "args": ["--filter", "@vab/mcp", "dev"],
      "cwd": "${ROOT//\\/\\\\}",
      "env": {
        "BRIDGE_API_URL": "${API_URL}"
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
  cat > "$destination" <<EOF
[mcp_servers.voice-agent-bridge]
command = "pnpm"
args = ["--filter", "@vab/mcp", "dev"]
cwd = "${ROOT}"

[mcp_servers.voice-agent-bridge.env]
BRIDGE_API_URL = "${API_URL}"
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
installer into a shared host configuration.
EOF
