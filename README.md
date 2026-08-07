# Knock Knock

**Knock Knock** — when your agent needs you, it knocks.

IDE-agnostic agent ↔ iPhone bridge (repo/code name: `voice-agent-bridge`).

**Lifecycle:** call Skill → create session → `update_progress` (mirror only) → Agent sets `needs_user` via `report_event` → phone interact → claim back to agent.

## Quick start (macOS MVP)

```bash
cp .env.example .env
pnpm install
pnpm dev:api
```

`pnpm dev:api` now starts the Rust/Cloudflare Worker in the sibling
`knock-knock/backend` repository and applies the local D1 migrations first.
Set `KNOCK_KNOCK_BACKEND_DIR` if that checkout is elsewhere. The former Node
server is available only as `pnpm dev:api:node` for migration diagnostics; it
is not a supported product runtime. The local Worker binds to `0.0.0.0` so a
physical iPhone on the same Wi-Fi can reach it; set
`KNOCK_KNOCK_BIND_IP=127.0.0.1` when you intentionally want loopback-only
development.

On a physical phone, enter the Mac's current LAN URL in Knock Knock's
Advanced connection settings. The address is intentionally not embedded in
the app because it can change between networks.

For the P0 beta, Codex is the canonical agent host. Its MCP entry is named
`voice-agent-bridge` in Codex config, and the canonical host smoke is:

```bash
pnpm test:canonical:codex
pnpm test:canonical:codex:multiturn
```

In another terminal:

```bash
pnpm test:e2e
```

`pnpm test:e2e` is the Rust Worker/D1 contract smoke. The legacy Node-only
regression remains available explicitly as `pnpm test:e2e:node`.

The multi-turn smoke verifies two separate phone decisions after the same
session resumes, preserving both `session_id` and `chat_id`.

Release-candidate checks:

```bash
pnpm test:installer
pnpm test:rc
```

### iOS Simulator

```bash
cd apps/ios
xcodegen generate
open VoiceAgentBridge.xcodeproj
```

Run on an iPhone Simulator (the latest iOS runtime is fine). Use the explicit
**Create an account** mode for a fresh local fixture, or sign in with an
existing e2e user.  
App polls `127.0.0.1:8787` — progress appears in Sessions; pushes only in **Dev Push**.

Full playbook: [docs/TESTING.md](docs/TESTING.md)

User installation and one-time agent pairing: [docs/INSTALL.md](docs/INSTALL.md).

Paperclip connection and same-session MCP handoff: [docs/PAPERCLIP.md](docs/PAPERCLIP.md).

For a physical iPhone on the same Wi-Fi, use the Mac LAN URL shown in Settings
(`http://192.168.8.17:8787` on the current dev network), allow notifications, and verify
the APNs token before running `pnpm signoff:phone`. The current physical target is the
iPhone 13 Pro; set `KNOCK_DEVICE_NAME` or `KNOCK_DEVICE_UDID` when using a different
connected iPhone. To verify the real two-turn interaction on one session, run
`pnpm signoff:phone:multiturn`; it requires a human tap for both turns.

Hosted HTTPS deployment, production APNs, monitoring, and the TestFlight/App
Store archive flow are documented in [docs/RELEASE.md](docs/RELEASE.md).

## Packages

| Path | Role |
|------|------|
| `contracts/` | OpenAPI + status cheat sheet |
| `apps/api` | Legacy Node control plane kept for migration diagnostics |
| `apps/mcp` | MCP server + CLI (when ready) |
| `apps/ios` | SwiftUI Simulator client |

The one-command installer supports Codex, Cursor, and Paperclip:
`pnpm skill:install -- --target all --api-url https://your-bridge.example.com`.

## MCP tools (5)

1. `create_or_resume_session`
2. `update_progress` — **never pushes**
3. `report_event` — may push
4. `get_pending_actions`
5. `submit_action_result`

## Daily Cursor use

- Project rule: `.cursor/rules/voice-agent-bridge.mdc`
- Project MCP: `.cursor/mcp.json` (key loaded from `.env.agent`)
- After restarting Cursor, ask the agent to use **voice-agent-bridge** tools on long tasks
- One-shot phone ping: `pnpm demo:phone`

## Real APNs

See [docs/APNS.md](docs/APNS.md). Without Apple keys, Dev Push inbox still works.
