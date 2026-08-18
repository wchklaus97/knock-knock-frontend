---
name: knock-knock
description: Use Knock Knock when Codex, Cursor, Paperclip, or another agent needs a human decision on the user's iPhone and must resume the exact same session after the reply.
---

# Knock Knock agent skill

Knock Knock is a decision channel, not a general chat assistant. Use it when a
long-running task needs an explicit human choice, approval, cancellation, or
confirmation.

## Install once

From the bridge checkout, install the skill and host snippets in one command:

```bash
pnpm skill:install -- --target all --api-url https://your-bridge.example.com
```

Targets are `codex`, `cursor`, `paperclip`, or `all`. For Paperclip, set
`PAPERCLIP_HOME` to the Paperclip project/config root, or pass
`--paperclip-skills-dir` and `--paperclip-config-dir`. The installer writes an
isolated MCP snippet and never replaces a host's main config file.

## First-time setup

The user installs the Knock Knock iPhone app and signs in. In the app, open
**Settings → Connect an Agent → Generate pairing code**. From this agent host,
claim the one-time code:

```bash
pnpm --filter @vab/mcp exec tsx src/cli.ts pair \
  --code CODE_FROM_IPHONE \
  --label "codex" \
  --host "codex" \
  --write-env .env.agent
```

Keep `.env.agent` private. Restart the MCP host after pairing. The host needs:

- `BRIDGE_API_URL` — the reachable Knock Knock API URL
- `BRIDGE_AGENT_KEY` — the key written by `vab pair`

Agent keys are scoped to one paired agent. Rotate a leaked key from the
account's agent management endpoint before continuing work.

## Session lifecycle

1. At the beginning of a long or decision-bearing task, call
   `create_or_resume_session` and save the returned `session_id` in the agent
   run context.
2. Call `update_progress` for ordinary progress. It never notifies the phone.
   Always send a truthful status and short message at start and meaningful
   milestones. Send `percent` only when the agent has a reliable estimate:
   `0` means genuinely started, intermediate values mean measured/estimated
   progress, and `100` is reserved for completed work. If no reliable estimate
   exists, omit `percent`; the app will show an indeterminate working state,
   not a misleading `0%`.
3. When the user must decide, call `report_event` with the exact `session_id`,
   `status: "needs_user"`, a short `summary` or `facts`, and explicit action
   ids.
4. Call `get_pending_actions` with that same `session_id` and wait for the
   phone response. Do not create a new session while waiting.
5. Execute only the claimed action, then call `submit_action_result` with the
   action id. A retry is safe and returns the stored result. After a successful
   result, resume the same `session_id` (and `chat_id` when present), call
   `update_progress` again, and continue the original task; do not create a
   new session for the next question in the same task.

When idle, poll `get_user_asks`. That is how the iPhone **Ask {agent}** dock
knows the Mac host is listening. If an ask arrives, resume the returned
`session_id` with `skill_id` `phone.ask` and the transcript in `facts`. Do not
invent tool names. Phone `send_message` / reminder / draft / history shortcuts
are local commands and will not appear here.

Example progress calls:

```text
update_progress(session_id, status="running", message="Inspecting deployment")
update_progress(session_id, status="running", message="Tests are halfway done", percent=50)
```

The first call intentionally has no percentage when the agent cannot estimate
the work. Every agent host should follow this same rule so Codex, Cursor,
Paperclip, and future adapters render progress consistently.

## Safety rules

- Never invent a session id or attach a phone answer to another task.
- Do not use `needs_user` for routine progress.
- Include only the actions the agent is prepared to execute.
- Treat destructive actions as requiring the phone confirmation gate.
- If the MCP server is unavailable, use the `vab` CLI with the same session
  lifecycle; do not bypass the bridge with an unrelated chat message.
