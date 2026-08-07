#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/knock-knock-installer.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

HOME="$TEMP_ROOT/home" \
PAPERCLIP_HOME="$TEMP_ROOT/paperclip" \
bash "$ROOT/scripts/install-agent-skill.sh" --target all --api-url https://bridge.example.test

test -f "$TEMP_ROOT/home/.codex/skills/knock-knock/SKILL.md"
test -f "$TEMP_ROOT/home/.codex/skills/knock-knock/voice-agent-bridge.toml"
test -f "$TEMP_ROOT/home/.cursor/rules/knock-knock.mdc"
test -f "$TEMP_ROOT/home/.cursor/knock-knock-mcp.json"
test -f "$TEMP_ROOT/paperclip/skills/knock-knock/SKILL.md"
test -f "$TEMP_ROOT/paperclip/knock-knock-mcp.json"
grep -q 'https://bridge.example.test' "$TEMP_ROOT/paperclip/knock-knock-mcp.json"
grep -q 'voice-agent-bridge' "$TEMP_ROOT/home/.codex/skills/knock-knock/voice-agent-bridge.toml"

echo "installer smoke: passed"
