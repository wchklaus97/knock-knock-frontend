# Agent notes — Knock Knock

Product name: **Knock Knock**. Code/MCP id may still say `voice-agent-bridge`.

## Local development config

Local test credentials are loaded from the untracked `.env.agent` file and
must never be shipped in a Release app. The MCP/CLI can use the Mac loopback
through `BRIDGE_API_URL`; the physical iPhone must be configured with the
Mac's current LAN URL in Settings. No LAN address is embedded in the app.

Physical validation target: the user's iPhone 13 Pro. The sign-off scripts
auto-detect that device or accept `KNOCK_DEVICE_UDID` explicitly. The expected
build is derived from `apps/ios/project.yml` and can be overridden with
`KNOCK_EXPECTED_BUNDLE_VERSION`.

## Daily phone loop

1. Ensure API: `pnpm dev:api`
2. MCP server `voice-agent-bridge` should be enabled in Cursor
3. For long work: create session → progress → `needs_user` only when needed → poll pending → result

Paperclip can host the same stdio MCP server through its governed Tool Gateway;
keep the bridge agent key in Paperclip secrets and persist the returned
`session_id`. See `docs/PAPERCLIP.md` for the exact connection shape.

## CLI fallback

```bash
source scripts/use-agent-env.sh
pnpm --filter @vab/mcp exec tsx src/cli.ts session --skill deploy.result --title "…"
pnpm --filter @vab/mcp exec tsx src/cli.ts progress --session ses_… --status running --message "…"
pnpm --filter @vab/mcp exec tsx src/cli.ts event --session ses_… --status needs_user
pnpm --filter @vab/mcp exec tsx src/cli.ts pending
pnpm --filter @vab/mcp exec tsx src/cli.ts result --action act_… --ok true
```
