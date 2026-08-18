# Paperclip integration — Knock Knock

Knock Knock is the phone decision channel for an agent run. Paperclip remains
the orchestration/control-plane UI; this bridge owns the iPhone notification,
session-specific decision, confirmation, and return path to the same agent.

## Supported connection shape

Use the bridge's existing stdio MCP server as a governed Paperclip tool
connection. The command is:

```text
pnpm --filter @vab/mcp dev
```

The connection must run from this repository and receive these environment
variables from Paperclip's secret/template mechanism:

```text
BRIDGE_API_URL=http://127.0.0.1:8787
BRIDGE_AGENT_KEY=<inject from a Paperclip secret; never commit this value>
```

Paperclip's Tool Gateway/stdio connection should pin the command, working
directory, allowed environment keys, and the five allowed tools. Keep the
bridge agent key scoped to the Paperclip agent that owns the run. Do not put it
in a checked-in MCP file or a shared global environment.

The equivalent connection shape, with the secret intentionally omitted, is:

```json
{
  "name": "knock-knock",
  "command": "pnpm",
  "args": ["--filter", "@vab/mcp", "dev"],
  "cwd": "/path/to/knock-knock-frontend",
  "env": {
    "BRIDGE_API_URL": "http://127.0.0.1:8787",
    "BRIDGE_AGENT_KEY": "INJECT_FROM_PAPERCLIP_SECRET"
  },
  "allowed_tools": [
    "create_or_resume_session",
    "get_user_asks",
    "update_progress",
    "report_event",
    "get_pending_actions",
    "submit_action_result"
  ]
}
```

## Same-session communication contract

Persist the bridge `session_id` in the Paperclip run/agent context after the
first `create_or_resume_session` response. On a resumed run, pass that exact
`session_id`; if no run context is available, use a stable, unique
`idempotency_key` for the Paperclip run. `chat_id` is metadata only and is not
the resume key.

```text
Paperclip run starts
  └─ create_or_resume_session(skill_id, idempotency_key/chat_id)
       └─ save returned session_id in run context
            ├─ update_progress(...)                 [never phones the user]
            ├─ report_event(needs_user, actions)    [push/inbox to iPhone]
            ├─ get_pending_actions(session_id)      [wait/claim the phone answer]
            ├─ execute the selected action
            └─ submit_action_result(action_id, ...) [same session continues]
```

For a destructive action, the iPhone first returns `needs_confirm=true`; only
after the user confirms does the action become claimable. A phone cancellation
is queued as a marked result, so the Paperclip agent can continue without
executing the cancelled operation.

## Verification checklist

1. Start the API and verify `/health` reports `push_mode: both` and
   `apns_ready: true`.
2. Configure the Paperclip connection with a real agent key supplied through a
   secret, then call `create_or_resume_session`.
3. Call `update_progress` and verify no phone push is created.
4. Call `report_event` with `status=needs_user` and `actions=["rollback"]`.
5. On iPhone, open the exact knocked session, choose **Rollback**, and confirm.
6. In the same Paperclip run, call `get_pending_actions` with the saved
   `session_id`, execute only the claimed action, and call
   `submit_action_result`.
7. Retry `submit_action_result` with the same `action_id`; the stored result
   must be returned without a second execution.

Run the local boundary smoke with:

```bash
pnpm test:paperclip
```

This starts the same stdio MCP command that Paperclip would govern, verifies
all five tools, resumes the exact returned `session_id`, simulates the phone
reply with the demo user, and completes/retries the action through MCP. A
Paperclip-hosted
connection is not claimed as executed here because Paperclip is not installed
in this workspace and its Tool Gateway is experimental/off by default until
explicitly enabled. The configuration above is the production integration
boundary to exercise when a Paperclip instance is available.

## Security and operations

- Use a separate bridge agent key per Paperclip agent or environment.
- Allow only the five bridge tools; do not expose the API's user/admin routes
  through the MCP connection.
- Keep `BRIDGE_API_URL` on loopback when Paperclip runs on the Mac. The iPhone
  uses the Mac's LAN URL configured in the iOS app.
- Rotate the bridge key through Paperclip's secret store if it is exposed.
- Treat Paperclip's audit/approval policy as an additional control plane; the
  Knock Knock confirmation is the human decision gate immediately before the
  agent action is claimable.

References: [Paperclip Tool Gateway](https://docs.paperclip.ing/reference/api/tool-gateway/),
[Paperclip agent adapters](https://docs.paperclip.ing/guides/org/agent-adapters/),
and [Paperclip repository](https://github.com/paperclipai/paperclip).
