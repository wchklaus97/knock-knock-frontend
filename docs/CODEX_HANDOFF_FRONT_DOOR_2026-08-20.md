# Codex handoff — Voice front door + Staging daily use (2026-08-20)

Copy this entire file into a long-running Codex task. Work in the two worktrees below. Do **not** Production-deploy. Do **not** enable real message sending. Do **not** put Gemma in Release. Do **not** commit secrets or `gauntlet-workbench.md`.

Talk to the user in simple English or simple Chinese when they ask.

---

## Product (one sentence)

Knock Knock is a **phone decision inbox** for coding agents. Hold-to-speak is a **front door** to the selected Home MCP agent. Gemma / deterministic parser = **ears**. Home MCP agent = **hands**. Phone = mic + confirm UI.

---

## Worktrees (absolute paths)

| Side | Path | Branch | Remote tip (approx) |
|------|------|--------|---------------------|
| Backend | `/Users/klaus_mac/Projects/01-Active/knock-knock/backend/.worktrees/structured-memory-backend-v2` | `gauntlet/staging-confirm-drain-20260817` | includes `f98751c` Ask routes |
| iOS / MCP | `/Users/klaus_mac/Projects/01-Active/voice-agent-bridge/.worktrees/structured-memory-ios-v2` | `voice-agent-front-door-20260818` | tip `693eab7` + large uncommitted delta |

Repos:

- Backend: `https://github.com/wchklaus97/knock-knock-backend`
- Frontend: `https://github.com/wchklaus97/knock-knock-frontend`

Older long handoff (broader Phase 4/5 history): `docs/CODEX_HANDOFF.md` in the iOS repo. **This file supersedes it for the front-door / Staging-daily slice.**

---

## Hard locks (do not violate)

1. **No Production deploy.**
2. **No real send:** Staging must stay `action_provider_mode=disabled`, `action_provider_ready=false`, `action_message_enabled=false`.
3. **No Gemma in Release:** `signedGemmaQualifiedForRelease = false`.
4. **No E5 / ranking in `search_history`.**
5. **iOS 15 floor stays** for the main app.
6. **13 Pro = deterministic parser only.** 17 Pro Max Staging/Debug may use Gemma as ears.
7. Do **not** invent skill names on device. Unknown / CJK / non-shortcut speech → Ask.
8. Phone never `POST /v1/sessions`. Worker creates `phone.ask` session on Ask POST.
9. Confirming a phone **command** does not send it to the Home agent.
10. Do **not** print `vak_` keys, pairing codes, or JWTs in replies.

---

## Environments (three separate worlds)

| Env | URL | Notes |
|-----|-----|-------|
| Local | `http://127.0.0.1:8787` | Own D1; often down; phone Offline if stuck here |
| Staging | `https://knock-knock-backend-staging.wch-klaus.workers.dev` | **Current target** |
| Production | `https://knock-knock-backend-production.wch-klaus.workers.dev` | Do not deploy / do not point daily UAT here |

Agent keys and pairing codes are **environment-scoped**. Local key ≠ Staging key ≠ Production key.

Staging health (verified 2026-08-20):

```text
ok=true
version=f98751ce1b51ddac1d376d40a8d4c80e71d4753b
action_provider_mode=disabled
action_provider_ready=false
action_message_enabled=false
apns_ready=true
```

---

## Devices

| Device | CoreDevice UDID | Role | Installed build (last known) | Ears |
|--------|-----------------|------|------------------------------|------|
| iPhone 13 Pro | `741C39D8-8BFE-5E63-A06A-E194F3E0E5A2` | USB + iPhone Mirroring desk phone for agent | **0.1.0 (32)** Staging | Deterministic parser |
| iPhone 17 Pro Max | `0B1E71C6-8C38-55F0-9B91-6D547F034912` | Human UAT | was **30**, then **32** if USB install succeeded while present | Staging/Debug Gemma ears OK |

Both phones must use **Staging** URL above. Old `vab.apiBase` LAN / `127.0.0.1` caused Offline; Staging build now ignores leftover development URLs when bundled HTTPS exists.

Mac MCP Staging agent (paired earlier):

- **agent_id:** `agt_765c46e4cd40330aa075f8528306b3b2`
- **label:** `cursor-staging`
- Credentials file: iOS worktree `.env.agent.staging` (mode 0600; never commit)
- Wrong agents to avoid for Ask UAT: `apns-gate-…`

---

## Product rules already implemented

### Voice routing

English local shortcuts only:

- `search_history`
- `create_reminder`
- `create_draft`
- `send_message` (Staging provider still disabled)

Everything else (CJK / mixed / unknown) with a selected agent → `POST /v1/phone/agents/{id}/asks` with raw transcript.

Exact Cantonese UAT phrase: `今日天氣點樣幫我發俾 Peter`  
Incomplete English send (`Say him a message`) stays local clarification, not Ask.

### Listening clock (exclusive 90s)

Worker and iOS must match:

- Listening iff `seen_ms + 90_000 > now_ms` / iOS `age < 90`
- Exact 90.000s = **not** listening
- Idle Home rows: **Listening / Not listening**, never **Connected**
- Header pill: API Connected / Offline / Checking
- Host not listening → HTTP **409** `agent_not_listening` (distinct from confirm/cancel 409)

### MCP Ask loop

```text
phone Ask POST → Worker phone.ask session
Mac MCP heartbeat GET /v1/agents/me/asks?claim=false (20s)
claim via get_user_asks → resume session_id → progress / needs_user / pending / result
```

Tools on worktree MCP: `create_or_resume_session`, `get_user_asks`, `update_progress`, `report_event`, `get_pending_actions`, `submit_action_result`.

Cursor launcher: `scripts/knock-mcp.sh`  
Config points at worktree + Staging + `.env.agent.staging` (see `~/.cursor/mcp.json`).

### Credential binding (permanent guard)

- Staging URL must load Staging-bound env (prefer `.env.agent.staging`).
- Local key refused for Staging (no silent mix).
- `vab pair --write-env .env.agent` against Staging rewrites to `.env.agent.staging`.
- `knock-mcp.sh` unsets inherited local `BRIDGE_AGENT_KEY` before start.
- Heartbeat starts **after** MCP stdio connect (2s delay) so Cursor discovery does not hang.

### Connectivity fix (build 32)

Mac/phone often get **IPv6 fail + IPv4 OK** to Staging Workers.  
App now retries connect failures over **IPv4+SNI** (`IPv4HTTPSClient.swift`).  
Error banners include hostname: `/v1/phone/sync via knock-knock-backend-staging…`.

### 13 Pro UX for desk development

- Login bootstrap auto-prepares deterministic voice (no Gemma download).
- Home dock copy: **Enable hold to talk** (not “Prepare in Settings”).

---

## What is done vs not done

### Done in code (mostly uncommitted on top of branch tips)

**Backend**

- `src/asks.rs`: Ask create/list/claim, `LISTENING_WINDOW_SECS = 90`, exclusive edge tests
- `src/db.rs`: `now_ms()` seam
- Scripts: `scripts/asks-listening-window-tests.sh`, `scripts/staging-ask-front-door-uat.sh`
- Wired into `.github/workflows/backend-ci.yml` and `scripts/phase45-release-gate.sh`
- Staging Worker already serves Ask at version `f98751c…`

**iOS**

- Unified `selectedAgentId` Ask target; dock `Ask {label}`
- Ask POST path; 409 `agent_not_listening` mapping
- Listening/Not listening idle rows
- Confirm copy: command confirm does **not** send to Home agent
- Leftover LAN/localhost ignored when Staging HTTPS is bundled
- IPv4 HTTPS fallback
- Tests: `CantoneseAskWorkflowTests`, `DynamicVoiceWorkflowTests`, listening-truth pins, IPv4 policy test
- Automation: `scripts/ios-listening-truth-tests.sh`, `pnpm test:ios:listening`
- CI: `.github/workflows/ios-listening-truth.yml`

**MCP**

- `get_user_asks`, `listening.ts` heartbeat, Staging env binding, `knock-mcp.sh`, skill updates

### Not done / user-gated

1. **Human Staging daily UAT on 17 Pro Max still not signed off:** Connected + select `cursor-staging` + hold-say Ask + Mac claims ask.
2. 13 Pro may still show Offline until unlock + Retry after build 32 IPv4 fix is confirmed.
3. Worktrees **not committed / not PR’d** for the latest Offline/IPv4/MCP-bind deltas (front-door base commit exists on iOS as `693eab7`; later fixes are dirty).
4. App Store / Pro subscription / Production = later phase only after Staging daily works.
5. Live microphone-to-durable-command on 13 Pro historically unproven; Ask path is the intended 13 Pro proof now.

### Complete-app plan (phased)

Agreed with user: Staging daily first, then App Store later.

0. Land PRs (no secrets / no gauntlet workbench)  
1. Staging daily: knock + decide + Ask `cursor-staging`  
2. Close voice front door (13 Pro Ask, Release still no Gemma, send still off)  
3. App Store / Pro only with separate human approval  

Plan file (Cursor): `~/.cursor/plans/complete_knock_knock_6590f32d.plan.md`  
Older front-door plan (do not edit unless asked): `~/.cursor/plans/voice_agent_front_door_f5658348.plan.md`

---

## How to verify (no phone required for most)

```bash
# Backend
cd /Users/klaus_mac/Projects/01-Active/knock-knock/backend/.worktrees/structured-memory-backend-v2
./scripts/asks-listening-window-tests.sh
./scripts/staging-ask-front-door-uat.sh

# iOS listening-truth
cd /Users/klaus_mac/Projects/01-Active/voice-agent-bridge/.worktrees/structured-memory-ios-v2
pnpm test:ios:listening
# simulator preferred: 830F3979-F680-478F-B77F-85FBA0013A3A
# needs: xcodegen, KNOCK_SKIP_E5_COPY=YES, -skipMacroValidation -skipPackagePluginValidation

# MCP unit
cd apps/mcp
# use main checkout tsx via symlink if worktree has no install
tsx --test src/cli-support.test.ts src/listening.test.ts
```

Physical install pattern:

```bash
export KNOCK_SKIP_E5_COPY=YES
cd apps/ios && xcodegen generate
xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge \
  -configuration Staging \
  -destination 'platform=iOS,id=741C39D8-8BFE-5E63-A06A-E194F3E0E5A2' \
  -derivedDataPath /tmp/knock-voice-17promax-derived \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation \
  KNOCK_SKIP_E5_COPY=YES build
xcrun devicectl device install app --device 741C39D8-8BFE-5E63-A06A-E194F3E0E5A2 \
  /tmp/knock-voice-17promax-derived/Build/Products/Staging-iphoneos/VoiceAgentBridge.app
```

Disk is often tight under `/System/Volumes/Data`; reuse `/tmp/knock-voice-17promax-derived` when possible.

---

## Cursor MCP notes

- Server id in Cursor: `user-voice-agent-bridge` / config name `voice-agent-bridge`
- Prefer `scripts/knock-mcp.sh` (worktree) over main-checkout `pnpm --filter @vab/mcp dev`
- Main checkout MCP may lack `get_user_asks`
- After config change: toggle MCP / `mcp_auth`
- Live check: `get_user_asks` with `claim=false` should return `{ "asks": [] }` on Staging with valid key (not 401)

---

## Immediate next actions for Codex

### 2026-08-25: concrete Codex Thread binding implemented on Staging

- Codex exposes a stable `CODEX_THREAD_ID`; MCP now fails closed without it (or
  an explicit `KNOCK_KNOCK_CHAT_ID`).
- Migration `0017_agent_chat_bindings.sql` is applied to Staging D1 and is in
  the controlled Staging migration allowlist.
- MCP registers a 90-second listener lease and sends the chat and listener
  identity on every authenticated request.
- Phone Asks persist `binding_id`, `target_chat_id`, and
  `claimed_by_chat_id`; another chat cannot claim or answer them.
- A second chat cannot silently replace the listener. Explicit
  `takeover=true` is required; restarting the same chat resumes normally.
- iOS shows the bound chat title, keys voice conversation reuse by
  `agent_id|chat_id`, automatically recovers expired sessions, and preserves a
  useful partial speech transcript when Apple's final callback arrives late.
- Staging runtime acceptance passed: wrong chat 409, active chat 200, expired
  lease 409, silent takeover 409, explicit takeover 200, then restoration to
  the original Codex Thread.
- Staging Worker version: `codex-chat-binding-20260825T0818Z`; Production was
  not deployed, message/reminder providers remain disabled, APNS production is
  false, and voice model is disabled.
- iPhone 13 Pro has the Staging build installed. Remaining human gate: speak
  one Ask on the phone and verify claim, reply, spoken output, and a follow-up
  on the same bound Thread.

1. Confirm 13 Pro build 32 unlock → **Connected** to Staging (IPv4 fallback). If still Offline, capture error banner (host is now in the message).
2. Keep Mac MCP listening on `cursor-staging` via Staging env.
3. When user returns with 17 Pro Max: Connected → select **`cursor-staging`** → say `今日天氣點樣` → dock Asked → Mac `get_user_asks` claims.
4. Only after that: commit dirty front-door/IPv4/MCP-bind work into clean PRs (backend + frontend), no Production, no send-on.
5. Do not treat `/loop` as gauntlet-loop. If finishing against a bar, read `~/.cursor/skills/gauntlet-loop/SKILL.md`.

---

## Files to read first

Backend:

- `src/asks.rs`, `src/db.rs`, `scripts/asks-listening-window-tests.sh`

iOS:

- `Voice/LocalVoiceCommandController.swift`
- `DemoConfig.swift` (LAN ignore)
- `APIClient.swift` + `IPv4HTTPSClient.swift`
- `Models.swift` (`AgentListening`)
- `ProductionViews.swift` (idle Listening rows, prepare dock)
- `AppStore.swift` (bootstrap auto-prepare on 13 Pro)

MCP:

- `apps/mcp/src/index.ts`, `listening.ts`, `cli-support.ts`, `client.ts`
- `scripts/knock-mcp.sh`, `skills/knock-knock/SKILL.md`

---

## Do not do

- Production deploy / enable send / Gemma in Release / raise iOS 15 floor
- Commit `.env*`, keys, `gauntlet-workbench.md`
- Edit the old front-door plan file unless the user asks
- Restart the whole voice cathedral; stay on decision inbox + Ask front door
- Use wrong agent ids (`apns-gate-…`) for Ask UAT
