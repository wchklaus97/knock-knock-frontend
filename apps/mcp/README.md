# `@vab/mcp`

MCP server + `vab` CLI for [Voice Agent Bridge](../../contracts/openapi.yaml).

Tools call the Rust Worker at `KNOCK_KNOCK_API_URL` (preferred) or the
compatibility alias `BRIDGE_API_URL`, defaulting to `http://127.0.0.1:8787`,
with `BRIDGE_AGENT_KEY` → `X-Agent-Key`.

## Tools

| Tool | HTTP | Push |
|------|------|------|
| `create_or_resume_session` | `POST /v1/sessions` | never |
| `update_progress` | `POST /v1/sessions/{id}/progress` | **NEVER** |
| `report_event` | `POST /v1/sessions/{id}/events` | **MAY** (`needs_user`, or terminal + actions / `force_push`) |
| `get_pending_actions` | `GET .../actions/pending` | never; supports bounded `wait_ms` |
| `submit_action_result` | `POST /v1/actions/{id}/result` | never |

See [`contracts/schemas/mcp-tools.json`](../../contracts/schemas/mcp-tools.json) and [`contracts/STATUS.md`](../../contracts/STATUS.md).

## Env

```bash
export BRIDGE_API_URL=http://127.0.0.1:8787
# Or use the explicit Rust Worker name:
export KNOCK_KNOCK_API_URL=http://127.0.0.1:8787
export BRIDGE_AGENT_KEY=vab_...   # from pairing claim or agent create
```

## Scripts

```bash
# from repo root
pnpm install
pnpm --filter @vab/mcp dev
pnpm --filter @vab/mcp start
pnpm --filter @vab/mcp typecheck
pnpm --filter @vab/mcp cli -- pair --code ABCD12 --label laptop

# Save the scoped key for the MCP host (the file is created with mode 0600)
pnpm --filter @vab/mcp cli -- pair --code ABCD12 --label laptop --write-env .env.agent
```

## CLI (`vab`)

Subcommands: `pair`, `session`, `progress`, `event`, `pending`, `result`.

```bash
pnpm --filter @vab/mcp cli -- session --skill deploy.result
pnpm --filter @vab/mcp cli -- progress --session ses_xxx --status running --message "building" --percent 35
pnpm --filter @vab/mcp cli -- event --session ses_xxx --status needs_user --idemp k1
pnpm --filter @vab/mcp cli -- pending
pnpm --filter @vab/mcp cli -- result --action act_xxx --ok true
```

`submit_action_result` returns the stored completed action on a retry, so an agent can
recover from a lost HTTP response without executing the action twice. Result metadata
is sent as `output` (the API contract uses `output`, not `facts`).

`--percent` is optional. Omit it when the agent cannot estimate progress; do not
use `0` as a placeholder. The phone then shows an indeterminate working state
instead of a misleading zero-percent bar.

## Cursor MCP config

Add to Cursor MCP settings (e.g. `~/.cursor/mcp.json` or project `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "voice-agent-bridge": {
      "command": "pnpm",
      "args": ["--filter", "@vab/mcp", "dev"],
      "cwd": "/path/to/knock-knock-frontend",
      "env": {
        "BRIDGE_API_URL": "http://127.0.0.1:8787",
        "BRIDGE_AGENT_KEY": "REPLACE_WITH_AGENT_KEY"
      }
    }
  }
}
```

## Codex MCP config

```toml
[mcp_servers.voice-agent-bridge]
command = "pnpm"
args = ["--filter", "@vab/mcp", "dev"]
cwd = "/path/to/knock-knock-frontend"

[mcp_servers.voice-agent-bridge.env]
BRIDGE_API_URL = "http://127.0.0.1:8787"
BRIDGE_AGENT_KEY = "REPLACE_WITH_AGENT_KEY"
```
