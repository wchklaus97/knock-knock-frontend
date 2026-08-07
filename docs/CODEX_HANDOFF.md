# Codex handoff — Knock Knock (voice-agent-bridge)

Copy this entire file into a long-running Codex task. Work **only** in this repo unless you must touch Cursor MCP config under `~/.cursor/mcp.json`.

---

## Goal / purpose

**Product:** Knock Knock (`hk.knockknock.app`)  
**Repo / MCP id:** `voice-agent-bridge` at  
`/Users/klaus_mac/Projects/01-Active/voice-agent-bridge`

**Purpose:** When a coding agent (Cursor / Codex / CLI) finishes work or needs a human decision, it knocks the user’s iPhone. The user sees a summary, answers by UI (voice later), and the answer routes back to the **same** agent session.

**Not the goal:** general Siri assistant, chat replacement, or unrelated product features.

**Locked MVP loop:**

```text
Agent (MCP/CLI) → bridge API :8787 → iPhone app
  create session → update_progress (mirror only, never push)
  → report_event needs_user → push/inbox → user action (+ confirm if destructive)
  → agent get_pending_actions → submit_action_result
```

---

## Current status (as of handoff)

| Area | State |
|------|--------|
| API | **Rust Cloudflare Worker + D1 is the canonical runtime**; refresh-token rotation, audit history, scoped agent keys, security headers, local `PUSH_MODE=dev`, and APNs integration are covered by the Rust contract smoke. The old Hono + `node:sqlite` API is migration-only. |
| Production hardening | Fail-closed production JWT/CORS/HTTPS/APNs checks, persistent auth/audit tables, scoped agent-key rotation, request IDs, bounded auth password length |
| MCP | 5 tools + `vab` CLI; loads `.env.agent` |
| Agent installation | One command generates Codex, Cursor, and Paperclip skill/rule plus isolated MCP snippets; installer smoke passes |
| Paperclip boundary | `pnpm test:paperclip` passes the local governed stdio boundary: all 5 tools, exact session resume, simulated phone reply, claim/result, and idempotent retry |
| Release path | Docker + Caddy HTTPS deployment, production APNs fail-closed config, App Store export options, archive script, and TestFlight/App Store runbook |
| iOS | SwiftUI app; **build-19** markers; iOS 15.0 deployment floor for compatibility; warm/cute production visual system with vector mascot; decision-inbox filters (Needs me / Active / All) plus search; offline/connection state with retry; agent/skill/facts/expiry/progress detail; one-time pairing-code generation + copy; iOS 15-compatible navigation and empty states; full-screen knock overlay with direct session review; safe destructive confirmation with alternate-action path; Keychain JWT storage; APNs deep-link handling; notification diagnostics; formal simulator UI test for the destructive decision path |
| E2E script | `pnpm test:e2e` runs the canonical Rust Worker/D1 contract smoke; `pnpm test:e2e:node` is migration-only |
| Canonical host | Codex MCP/CLI; `pnpm test:canonical:codex` verifies the configured Codex bridge, and `pnpm test:canonical:codex:multiturn` verifies two replies on one session/chat |
| iOS tests | Xcode simulator passes 6/6 model tests and 2/2 formal UI tests (decision + pairing); physical UI runner is blocked before test execution by the iOS 26.6 Beta automation service timeout |
| MCP smoke | Direct stdio MCP server loop passes create/progress/needs_user/phone reply/claim/result/retry |
| Real phone | The user's physical target is the iPhone 13 Pro (iOS 26.6 Beta), which macOS reports as paired, unlocked, and running build-19. Build-19 has now passed a manual two-turn knock → review/rollback/confirm → result → follow-up knock/ack → result flow on one session/chat. Xcode's physical UI runner is signed but still times out while enabling automation mode before the test body. |
| Remaining external step | Continue the owner dogfood and invite external pilot users; the P0 real-device same-session evidence is complete. The iOS 15 deployment floor remains available for older compatible devices. |
| Entitlements | Debug uses `aps-environment=development`; Release switches to `production` |
| Demo user | Owns real 64-char APNs token |

---

## Local test references (not bundled in the app)

| Item | Source |
|------|--------|
| Email / password | `.env.agent` and local test fixtures |
| User / agent ids | Local D1 seed data; do not treat as production ids |
| Agent key | `.env.agent` → `BRIDGE_AGENT_KEY` |
| API Mac / MCP | `BRIDGE_API_URL` (normally the local loopback) |
| API iPhone | Current Mac LAN URL entered in the app's Advanced connection settings |
| Team | Spotlight Platform Limited / `TXKDW2YS44` |
| Bundle | `hk.knockknock.app` |
| APNs key | `secrets/AuthKey_664Y4CM7M3.p8` (gitignored), Key ID `664Y4CM7M3` |
| `APNS_PRODUCTION` | `false` (Xcode debug → sandbox) |

Do **not** commit secrets, `.env`, `.env.agent`, or `.p8` files.

---

## Your mandate (end-to-end)

Own the remaining **test → debug → fix → retest** loop until the Definition of Done below passes. Prefer small, focused fixes. Do not redesign architecture unless a bug requires it.

### Phase A — Prove the toolchain

1. `pnpm install` if needed; start API: `pnpm dev:api`.
2. `curl -s http://127.0.0.1:8787/health` → expect `ok: true`, `api: rust`, `runtime: cloudflare-worker`.
3. `pnpm test:e2e` — run the Rust Worker/D1 contract smoke.
4. iOS compile:  
   `cd apps/ios && xcodegen generate && xcodebuild -scheme VoiceAgentBridge -destination 'generic/platform=iOS' build`  
   Fix Swift errors until clean.
5. Confirm the bundle-derived `build-N` label is visible in UI.

### Phase B — Real iPhone knock loop

1. Ensure phone and Mac on same Wi‑Fi; API reachable at LAN IP.
2. Guide/verify: Xcode Run → Settings shows current **build-N** → **Test in-app knock popup** works.
3. Login as demo email/password; API base = LAN URL.
4. Settings: notification permission not DENIED; APNs token length 64; device row updates in DB.
5. From Mac:  
   `source scripts/use-agent-env.sh && pnpm demo:phone`  
   Expect on phone: orange bar and/or full-screen knock; Sessions/Pushes counts &gt; 0.
6. User taps action (destructive → confirm). Agent side:  
   `pnpm --filter @vab/mcp exec tsx src/cli.ts pending` then `result`.
7. Verify system APNs banner separately from in-app UI. If inbox works but banner fails: check permission, Focus, entitlements, sandbox vs production, API `[push] apnsSent=` logs. Script: `scripts/apns-test.mjs` (run from `apps/api` context / jose available).

### Phase C — Advance automated testing

1. Keep / extend `pnpm test:e2e` for N1–N11 in `docs/TESTING.md` (progress never pushes; needs_user requires actions; destructive confirm; TTL; session binding; concurrency; stale-state reconciliation).
2. Add regression coverage for:
   - `notifyUser` returns / logs `apnsSent` when token is 64-hex
   - mock `dev-` tokens skipped for APNs
   - iOS models decode real `/v1/phone/sessions` + `/v1/dev/pushes` payloads (fixture JSON tests if useful)
3. Document any new commands in `AGENTS.md` / `docs/TESTING.md` (update, don’t invent parallel docs unless needed).

### Phase D — Bugfix backlog (known + hunt)

Fix and retest anything that blocks the loop:

- [ ] iOS Codable/`Decodable` mismatches (already hit on `PendingAction`)
- [ ] Cold start without `bootstrapIfLoggedIn` / polling (should be fixed; verify)
- [x] Stale LAN IP in `DemoConfig` / UserDefaults removed; legacy values are cleared on upgrade
- [ ] Empty or wrong entitlements after `xcodegen`
- [ ] APNs accepted (200) but no banner → permission / Focus / topic / environment
- [x] In-app knock ignores retained pushes whose exact session is no longer waiting; current `needs_user` decisions remain visible (orange bar)
- [ ] Device re-register after reinstall (token `updated_at` refreshes)
- [ ] API restart / port 8787 conflicts
- [ ] MCP daily path in Cursor: `.cursor/mcp.json` + rule still valid

### Phase E — Stretch (only after A–D green)

- Headphones auto-announce (`voice_script`) polish  
- Stronger pairing UX  
- Do **not** change Bundle ID without Apple portal sync  
- Siri / Side Button wake = later, not MVP  

---

## Useful commands

```bash
cd /Users/klaus_mac/Projects/01-Active/voice-agent-bridge
pnpm dev:api
source scripts/use-agent-env.sh
pnpm demo:phone
pnpm signoff:phone
pnpm signoff:phone:watch
pnpm test:e2e
pnpm test:ios              # seeds a live decision and runs 4 model + 2 UI tests

cd apps/ios && xcodegen generate
xcodebuild -scheme VoiceAgentBridge -destination 'generic/platform=iOS' build

# Direct APNs probe (sandbox)
cd apps/api && node ../../scripts/apns-test.mjs
```

---

## Definition of Done (hand this back as done)

- [x] `pnpm test:e2e` green  
- [x] stale waiting-session metadata is reconciled before phone rendering  
- [x] iOS `xcodebuild` green with iOS 15.0 deployment target; compatibility Simulator full scheme passes (6/6 model tests + 2/2 UI tests)  
- [x] Simulator decision inbox shows build-19, search, Needs me / Active / All filters, facts/expiry detail, and pairing-code UI
- [x] Historical physical-device build-11 in-app popup and destructive loop verified  
- [x] Install build-16 and run the fresh knock/destructive loop on the currently connected iPhone 13 Pro
- [x] APNs sandbox transport and SpringBoard user-visible delivery logs verified on the currently connected iPhone; the iPhone Mirroring screenshot did not capture the transient banner
- [x] Install build-19 and launch the refreshed UI on the user's iPhone 13 Pro
- [x] Run the fresh build-19 two-turn knock/destructive/follow-up loop on the user's iPhone 13 Pro (manual taps; current runner still times out before test execution)
- [x] `AGENTS.md` + `docs/TESTING.md` updated if commands/credentials/IP changed  
- [x] Short summary of what was broken, what was fixed, and remaining risks  

---

## Constraints

- Stack: API (TypeScript/Hono), MCP, Swift/SwiftUI iOS, SQLite, shell.  
- Progress updates must **never** push; only `needs_user` / decision events.  
- Prefer fixing over redesign. No force-push, no committing secrets.  
- Ask the human only when a physical phone tap/permission dialog is required; otherwise automate.  
- If Mac IP changes, enter the new LAN URL in the phone app; no source file needs updating.
