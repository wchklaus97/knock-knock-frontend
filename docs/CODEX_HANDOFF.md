# Codex handoff — Knock Knock (voice-agent-bridge)

Copy this entire file into a long-running Codex task. Work **only** in this repo unless you must touch Cursor MCP config under `~/.cursor/mcp.json`.

---

## Goal / purpose

**Product:** Knock Knock (`hk.knockknock.app`)  
**Repo / MCP id:** `voice-agent-bridge` at  
`/path/to/knock-knock-frontend`

**Purpose:** When a coding agent (Cursor / Codex / CLI) finishes work or needs a human decision, it knocks the user’s iPhone. The user sees a summary, answers by UI (voice later), and the answer routes back to the **same** agent session.

**Not the goal:** general Siri assistant, chat replacement, or unrelated product features.

## Canonical backend architecture references

The backend contract is the sole protocol source of truth. This iOS handoff is a pointer only and must not copy the full architectural decisions; update the backend references first when the contract or architecture changes.

- [Backend architecture decisions](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/ARCHITECTURE_DECISIONS.md) — canonical architecture decisions (cross-repo placeholder).
- [Backend implementation roadmap](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/IMPLEMENTATION_ROADMAP.md) — canonical implementation sequencing (cross-repo placeholder).
- [Backend OpenAPI contract](https://github.com/wchklaus97/knock-knock-backend/blob/main/contracts/openapi.yaml) — canonical REST, SSE, error, and `CommandEnvelope v1` contract.
- [Voice model release runbook](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/VOICE_MODEL_RELEASE_RUNBOOK.md) — operator-owned Gemma license, signing, private-R2 staging, evaluation, and rollback steps.

## Current Phase 4/5 completion branch

The current completion branch is based on merged iOS `931c6bf`. It adds iOS 15
push-to-talk/VAD with Apple on-device speech recognition, strict app-owned
`CommandEnvelope v1` canonicalization, the LiteRT-LM 0.12 C runtime, signed
disk-backed model delivery/rollback, a 32-example multilingual fixture,
backend-owned UI/TTS presentation, and a crash-safe SQLite command checkpoint
written before POST. It also closes the audited foreground-start race,
production clarification path, permanent offline-failure visibility, and
identifier-free silent APNs-to-REST reconciliation path. A process-level
dispatcher handles pure background launches without waiting for a SwiftUI
view, background fetch results reflect the actual REST outcome, and a manual
Retry during an automatic retry pass is queued for the next pass. Newer
confirmation versions invalidate old local tokens, and History search uses the
same trimmed 1–200-character contract as Rust/OpenAPI. Exact test
counts and external gates are recorded in the
backend release matrix/report rather than duplicated here. A licensed Gemma 3
1B int4 artifact has now passed the signed UAT semantic/safety gate on simulator
and iPhone 17 Pro Max. iPhone 13 Pro now uses the approved fail-closed
deterministic parser instead of the latency-failing Gemma/270M paths; its 48-case
transcript policy gate passes, but real WAV/microphone evidence is still pending.
Real Staging sandbox APNs delivery and same-account two-device convergence have
now passed on the iPhone 13 Pro and iPhone 17 Pro Max. Production trust-key
approval, real microphone/device voice UAT, the final visual offline-status
transition, paired PR review, and human rollout approval remain separate gates.

Current final physical UAT, voice harness, offline UI, stability, and persistent
agent-pairing work is tracked in
[frontend Draft PR #26](https://github.com/wchklaus97/knock-knock-frontend/pull/26).
There is no paired backend code change for this slice; backend command safety was
re-verified independently.

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
| MCP | 5 tools + `vab` CLI; explicit environment-scoped pairing; workspace-root `.env.agent` with mode `0600`; restart authentication verified against Staging |
| Agent installation | One command generates Codex, Cursor, and Paperclip skill/rule plus isolated MCP snippets; installer smoke passes |
| Paperclip boundary | `pnpm test:paperclip` passes the local governed stdio boundary: all 5 tools, exact session resume, simulated phone reply, claim/result, and idempotent retry |
| Release path | Rust Cloudflare Worker/D1 HTTPS deployment, production APNs fail-closed config, monitoring/backup workflows, App Store export options, manual signing archive script, and TestFlight/App Store runbook |
| iOS | SwiftUI app; Build25 release candidate archive with production onboarding defaulting to account creation; iOS 15.0 deployment floor; warm/cute production visual system with vector mascot; decision-inbox filters (Needs me / Active / All) plus search; offline/connection state with retry; agent/skill/facts/expiry/progress detail; one-time pairing-code generation + copy; iOS 15-compatible navigation and empty states; full-screen knock overlay with direct session review; safe destructive confirmation with alternate-action path; Keychain JWT storage; APNs deep-link handling; notification diagnostics; simulator UI tests |
| E2E script | `pnpm test:e2e` runs the canonical Rust Worker/D1 contract smoke; `pnpm test:e2e:node` is migration-only |
| Canonical host | Codex MCP/CLI; `pnpm test:canonical:codex` verifies the configured Codex bridge, and `pnpm test:canonical:codex:multiturn` verifies two replies on one session/chat |
| iOS tests | The current branch has 206 simulator unit/integration cases: 197 passed, 9 opt-in physical/model cases skipped without their explicit environment, and 0 failed. The isolated Worker/D1 UI suite has 6 cases: 3 passed, 3 physical-device opt-in cases skipped, and 0 failed. Combined result: 212 total, 200 passed, 12 skipped, 0 failed. |
| MCP smoke | Direct stdio MCP server loop passes create/progress/needs_user/phone reply/claim/result/retry |
| Real phone | The UAT-signed Gemma 3 1B int4 artifact passes the complete 32-example gate on iPhone 17 Pro Max: semantic accuracy 1.000, high-risk false executions 0, command p95 1.546 seconds. On iPhone 13 Pro the semantic/safety checks pass, but command p95 is 4.844 seconds and therefore fails the 2-second latency gate. Both locked physical phones have received real Staging sandbox APNs. The iPhone 13 Pro also passed USB-observed true-airplane-mode launch, explicit SQLite retention, subsequent network reconciliation, and a controlled-route visual offline/cache test. Same-account two-device UAT passed on the exact backend session id. On iPhone 17 Pro Max, the 12-human-recording SpeechAnalyzer comparison remained below the accuracy gate; a 2,880-case single-process STT loop completed with zero crash and 157 ms p95, but started and ended at serious thermal state. iPhone 13 live microphone pilots failed closed; no successful durable voice command has yet been proved. |
| Remaining external step | Complete an online-started human-observed airplane-mode status transition, the 36+ independently labelled multi-speaker voice corpus, one successful live microphone-to-durable-command flow, and iPhone 13 cool-start thermal/interruption/cancellation UAT. Separately pin the production model key for newer-device Gemma. Production rollout remains human-approved. |
| Entitlements | Debug uses `aps-environment=development`; Release switches to `production` |
| Staging device metadata | A read-only aggregate confirms two valid physical APNs registrations under one user; no token/identity was printed. Real sandbox APNs delivery was user-confirmed on both locked phones. Same-account action-to-observer synchronization and exact-session UI convergence passed on both physical devices. |

---

## Local test references (not bundled in the app)

| Item | Source |
|------|--------|
| Email / password | `.env.agent` and local test fixtures |
| User / agent ids | Local D1 seed data; do not treat as production ids |
| Agent key | `.env.agent` → `BRIDGE_AGENT_KEY` |
| API Mac / MCP | Paired `.env.agent` stores `KNOCK_KNOCK_API_URL`, `BRIDGE_API_URL`, and `BRIDGE_AGENT_KEY`; pairing codes must use the exact issuing environment |
| API iPhone | Current Mac LAN URL entered in the app's Advanced connection settings |
| Team | Spotlight Platform Limited / `TXKDW2YS44` |
| Bundle | `hk.knockknock.app` |
| APNs key | Configured as Cloudflare Worker secrets; local `.p8` files remain gitignored |
| `APNS_PRODUCTION` | `false` (Xcode debug → sandbox) |

Do **not** commit secrets, `.env`, `.env.agent`, or `.p8` files.

---

## Physical-device signed voice-model UAT

Host filesystem paths are not reachable from an XCTest process running on an
iPhone. The signed-model golden test therefore keeps the existing host/simulator
configuration, but requires all three values together:

- `KNOCK_VOICE_MODEL_PATH`
- `KNOCK_VOICE_MODEL_MANIFEST_PATH`
- `KNOCK_MODEL_PUBLIC_KEY_BASE64`

A partial environment is a test failure. With no environment triple, the test
looks in the app's Documents container at:

```text
KnockKnockVoiceModelUAT/
  model.litertlm
  manifest.json
  public-key.base64
  required
```

The `required` marker makes missing or invalid staged inputs fail instead of
being reported as the ordinary unconfigured-model skip.

To stage an approved artifact on an installed development build, connect and
unlock the iPhone, obtain its CoreDevice UUID, and run:

```bash
scripts/ios-voice-model-uat.sh \
  --device "$KNOCK_DEVICE_UDID" \
  --model /absolute/path/to/model.litertlm \
  --manifest /absolute/path/to/manifest.json \
  --public-key /absolute/path/to/public-key.base64
```

The script accepts the equivalent path variables
`KNOCK_VOICE_MODEL_PATH`, `KNOCK_VOICE_MODEL_MANIFEST_PATH`, and
`KNOCK_MODEL_PUBLIC_KEY_PATH`. It validates the files and 32-byte Ed25519
public key, creates a private temporary payload, and uses `xcrun devicectl`
with the `appDataContainer` domain for `hk.knockknock.app`. It copies only to
`Documents/KnockKnockVoiceModelUAT`, does not print key material, does not
delete device data, and does not run the test. Run the exact targeted
`xcodebuild` command it prints after staging. That command removes the three
host-input variables from the test process so physical-device resolution cannot
accidentally select Mac-only paths. The marker intentionally remains in app
data, so subsequent targeted runs stay fail-closed until a valid payload is
staged again or the app data is deliberately reset by the operator.

### 2026-08-12 UAT evidence boundary

- Artifact: Gemma 3 1B IT dynamic-int4 LiteRT-LM, 584,417,280 bytes.
- Simulator: all 32 examples passed; semantic accuracy 1.000, high-risk false
  executions 0, command p95 1.476 seconds.
- iPhone 17 Pro Max: all 32 examples passed; semantic accuracy 1.000,
  high-risk false executions 0, command p95 1.546 seconds.
- iPhone 13 Pro: semantic accuracy 1.000 and high-risk false executions 0, but
  command p95 4.844 seconds, so the 2-second release target did not pass.
- The adjacent UAT public key proves artifact/manifest consistency. It is not a
  substitute for pinning the human-approved production release trust key.
- Raw model output, transcript text, key material, and the model artifact are
  not committed or printed by the UAT gate.

### 2026-08-12 release-safety closure and 270M decision

- A Release build now fails closed unless one valid 32-byte Ed25519 model
  public key is injected. The archive entry point accepts only an absolute,
  readable, non-symlink key file and creates private temporary key and
  Info.plist copies. Only their paths reach Xcode process arguments; the key
  content does not.
- Signature and hash verification are only the first activation gate. The app
  now opens the exact LiteRT-LM container before reporting `Ready`. A newly
  installed model that cannot initialize is quarantined and removed; an update
  restores the already verified predecessor, including after relaunch.
- The 304,005,120-byte Gemma 3 270M q8 candidate was evaluated only against the
  checked-in 32-example synthetic command set. The original prompt scored
  0.125 with command p95 2.469 seconds. JSON-schema constrained decoding was
  rejected because this model vocabulary is unsupported by the LiteRT FST
  constraint provider and therefore scored 0.000. A shortened unconstrained
  prompt improved accuracy to 0.500 with command p95 1.533 seconds. All runs
  recorded zero high-risk false executions, but none met the 0.950 accuracy
  gate.
- The 270M candidate is therefore rejected for iPhone 13 and staging. iPhone 13
  remains on deterministic parsing plus clarification; iPhone 17 Pro Max keeps
  the previously validated Gemma 3 1B path. The experimental prompt and
  constrained-decoding wiring are not part of the release code.
- Clean Simulator regression after these changes: 206 unit/integration tests
  executed with 197 passed, nine opt-in/environment tests skipped, and zero
  failures; six UI tests executed with three passed, three physical-device
  opt-in tests skipped, and zero failures. The combined result was 212 total,
  200 passed, 12 skipped, and zero failed. The
  destructive confirmation, Today/Week, drawer, Settings, and pairing flows
  passed against one isolated local Rust Worker/D1 fixture.

### 2026-08-12 iPhone 13 deterministic voice path

The iPhone 13 Pro/Pro Max production path now selects the fail-closed
`DeterministicCommandGenerator`; the rejected 270M candidate is never loaded. The
48-example transcript policy gate passes 36/36 commands and 12/12 clarifications,
with 1.000 command accuracy for all three locales and zero high-risk false
executions. This is not physical STT evidence. The complete physical plan,
evidence levels, privacy boundary, and remaining gates are recorded in
[`IPHONE13_VOICE_UAT.md`](IPHONE13_VOICE_UAT.md).

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
cd /path/to/knock-knock-frontend
pnpm dev:api
source scripts/use-agent-env.sh
pnpm demo:phone
pnpm signoff:phone
pnpm signoff:phone:watch
pnpm test:e2e
pnpm test:ios              # checks the Rust Worker and runs the current unit + isolated UI fixtures

cd apps/ios && xcodegen generate
xcodebuild -scheme VoiceAgentBridge -destination 'generic/platform=iOS' build

# Direct APNs probe (sandbox)
cd apps/api && node ../../scripts/apns-test.mjs
```

---

## Definition of Done (current release candidate)

- [x] Rust Worker/D1 contract, Paperclip boundary, canonical Codex multi-turn, RC security, installer, and type checks pass.
- [x] Rust backend has 76 unit tests plus fmt, Clippy, WASM, Worker build, local contract, and release gates passing.
- [x] Current iOS regression passes 212 tests: 200 passed, 0 failed, and 12 opt-in/environment tests skipped. This includes the isolated fixture-backed UI flows.
- [x] The signed-model semantic/safety gate runs on both phones; iPhone 17 Pro Max passes the full model latency gate. iPhone 13 now selects the deterministic parser because both Gemma candidates failed its release requirements.
- [x] Production Worker health, metrics, migrations, secrets presence, and D1 backup evidence are verified.
- [x] Build21 is officially signed with production APNs entitlement and uploaded to TestFlight.
- [x] Frontend and backend are published in their independent GitHub repositories and synchronized by the root submodules.
- [ ] The iPhone 17 Pro Max signed model and iPhone 13 Pro deterministic parser each pass their physical audio accuracy, safety, and latency gates; the production model trust key remains open for Gemma devices.
- [ ] Real microphone → STT → intent → command → backend → TTS UAT and thermal testing pass on both phone classes.
- [x] Real Staging sandbox APNs delivery, true-airplane cache/reconciliation, and simultaneous same-account two-device convergence are observed.
- [ ] The online-started airplane-mode run visibly proves the offline status indicator transition before final release approval.
- [ ] GitHub Actions D1 backup runs once after `CLOUDFLARE_API_TOKEN` is added as an Actions secret.

---

## Constraints

- Stack: Rust Cloudflare Worker/D1, MCP, Swift/SwiftUI iOS, shell; legacy TypeScript/Hono is migration-only.  
- Progress updates must **never** push; only `needs_user` / decision events.  
- Prefer fixing over redesign. No force-push, no committing secrets.  
- Ask the human only when a physical phone tap/permission dialog is required; otherwise automate.  
- If Mac IP changes, enter the new LAN URL in the phone app; no source file needs updating.
