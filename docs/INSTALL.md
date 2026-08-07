# Install and pair Knock Knock

This is the intended user path: install the iPhone app, install the agent Skill,
pair once, then let the agent ask for decisions on the phone.

## 1. Start or deploy the bridge API

For a local Mac setup:

```bash
pnpm install
pnpm dev:api
```

The agent and phone must be able to reach the same `BRIDGE_API_URL`. A physical
iPhone cannot use `127.0.0.1` for a Mac service; use the Mac LAN address or a
deployed HTTPS API. `pnpm dev:api` binds the local Rust Worker to the LAN by
default; use `KNOCK_KNOCK_BIND_IP=127.0.0.1` for loopback-only development.

## 2. Install the Skill

From the Knock Knock repository:

```bash
pnpm skill:install -- --target all --api-url https://your-bridge.example.com
```

This installs the shared Skill for Codex, the decision rule and MCP snippet for
Cursor, and the Skill/MCP snippet for Paperclip. For a Paperclip workspace,
set `PAPERCLIP_HOME=/path/to/paperclip-project` first. The script writes
`<paperclip-home>/skills/knock-knock/SKILL.md` and
`<paperclip-home>/knock-knock-mcp.json`; import the latter into Paperclip's
governed MCP Tool Gateway.

## 3. Pair the agent

1. On first use, choose **Create an account**, enter an email and a new
   password of at least eight characters, then tap **Create account**. The
   password is chosen by you; it is not an Apple, TestFlight, or Codex
   password. If the email is already registered, switch to **Sign in** and use
   that account's password.
2. Open **Settings → Connect an Agent**.
3. Tap **Generate pairing code**.
4. Claim the code from the agent host:

```bash
pnpm --filter @vab/mcp exec tsx src/cli.ts pair \
  --code 123456 \
  --label "codex" \
  --host "codex" \
  --write-env .env.agent
```

The command creates a scoped agent key and writes it with mode `0600`. Restart
the MCP host after pairing. A pairing code is single-use and expires.

For the P0 beta, **Codex is the canonical agent host**. Cursor and Paperclip
remain supported adapters, but their hosted loops are not release gates until
the Codex path has a repeatable real-device result.

## 4. Configure the MCP host

Use the snippets in `skills/knock-knock/codex-config.toml` or
`skills/knock-knock/cursor-mcp.json`, replacing `/path/to/voice-agent-bridge`
with the checkout path. The MCP process reads `BRIDGE_AGENT_KEY` from the
private `.env.agent` file in that checkout.

Paperclip should install the Skill for its agent and run the same MCP server
through its governed Tool Gateway, with `BRIDGE_API_URL` and
`BRIDGE_AGENT_KEY` supplied as agent-scoped secrets. The bridge receives only
explicit session lifecycle calls, not a general assistant conversation.

## 5. Verify the first decision

The Skill lifecycle is:

```text
create_or_resume_session
        ↓
update_progress
        ↓
report_event(needs_user)
        ↓
phone decision
        ↓
get_pending_actions
        ↓
submit_action_result
```

The original `session_id` must be preserved for every step.
