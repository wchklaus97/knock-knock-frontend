# Release-candidate Testing — macOS + iOS + physical iPhone (Knock Knock)

Goal: prove the full lifecycle locally, then complete the remaining human-controlled
production steps on the iPhone 13 Pro.

App display name: **Knock Knock**.

Latest verification: the Rust backend has 46 passing unit tests, and the iOS simulator
regression passes 36 unit tests plus 3 UI tests against a fresh local Rust Worker/D1:
login/create-account mode → knock → exact session → destructive action → second
confirmation → queued, and Settings → generate pairing code → copy. The Rust Worker contract smoke, Codex canonical multi-turn smoke,
Paperclip boundary smoke, TypeScript checks, MCP build, and APNs unit tests are green.
The legacy Node API remains an explicit migration diagnostic, not the product source of
truth. The RC smoke additionally verifies refresh-token rotation, scoped Agent-key
rotation, audit history, and Prometheus metrics. Build25 is the current iOS release
candidate and has been uploaded; App Store Connect processing is still pending. Build20
remains the installed build on the user's iPhone 13 Pro (iOS 26.6 Beta).

The physical UI-test runner is signed and installs, but Xcode 26.6 times out before the test
body while enabling automation mode on this iOS 26.6 Beta device. The app itself remains
reachable. An earlier build has passed a manual two-turn physical flow on one session/chat;
the current production account creation, latest-build installation, and final taps remain
human-controlled steps.

## Architecture under test

```text
Agent (Codex canonical MCP / CLI)
        │  X-Agent-Key
        ▼
Rust Cloudflare Worker :8787  (local D1, PUSH_MODE=dev)
        │  user JWT
        ▼
iOS Simulator app  ←── also polls GET /v1/dev/pushes
```

In `PUSH_MODE=dev`, every pushable `report_event` is written to a **dev push inbox**.
The local Rust Worker uses this mode; a hosted environment may separately use
`PUSH_MODE=apns` or `both` after production APNs is configured.
The Simulator app (and `scripts/e2e-mvp.sh`) treat that inbox as a stand-in for APNs.

## Happy path (imagine interacting)

1. **Boot API** on Mac: `pnpm dev:api`
2. **Register / login** as the phone user.
3. **Open iOS Simulator**, run `VoiceAgentBridge`, login with same account.
4. App registers device as `ios_simulator` and starts polling `/v1/dev/pushes` + `/v1/phone/sessions`.
5. On Mac terminal (or Cursor/Codex MCP):
   - `create_or_resume_session` with `skill_id=deploy.result`
   - several `update_progress` (`running`…)
6. **Expect on Simulator list**: session shows progress text; **no banner / no inbox push**.
7. Agent calls `report_event` with `status=needs_user`, actions `["rollback","ack"]`.
8. **Expect on Simulator**:
   - new item in Dev Push inbox
   - session jumps to top as **needs_user**
   - summary + action buttons appear
9. Tap **回滚** → App asks second confirm → confirm.
10. Agent `get_pending_actions` receives `rollback` claimed → `submit_action_result`.
11. Simulator session moves out of needs_user (running/closed depending on result).

## Negative / gate tests

`pnpm test:e2e` runs all eleven API gates below. The TTL case advances the action expiry
directly in the local SQLite file so the test stays fast and deterministic.

| # | Case | Expected |
|---|------|----------|
| N1 | Only `update_progress` | `/v1/dev/pushes` stays empty |
| N2 | `needs_user` without actions | API 400 |
| N3 | Destructive without confirm | stays `awaiting_confirm`, not claimable |
| N4 | Confirm after destructive TTL | action expired, not executable |
| N5 | Two sessions needs_user | reply binds to tapped `session_id` only |
| N6 | Empty wake (no pending) | App shows empty state, no chat |
| N7 | Concurrent phone reply | one action, idempotent pending confirmation |
| N8 | Concurrent pairing claim | exactly one agent receives the one-time code |
| N9 | Destructive cancellation | cancellation is queued back to the agent with a marker |
| N10 | Concurrent event idempotency | one stored event for duplicate requests |
| N11 | Stale waiting metadata | phone list reconciles missing/expired actions before rendering |

## Simulator-specific notes

- Use any available iOS runtime in Simulator for UI checks; compile with deployment target 15.0.
- App talks to `http://127.0.0.1:8787` — on Simulator, localhost is the Mac.
- Simulator registrations are deliberately excluded from APNs delivery; only physical
  `platform=ios` registrations with a 64-hex token are sent to Apple.
- No real speech required for MVP: buttons + text field simulate utterance.
- Optional later: AVSpeechSynthesizer reads `voice_script` when a mock “headphones” toggle is on.

## Commands

```bash
# Terminal A
pnpm install
cp .env.example .env
pnpm dev:api

# Terminal B — canonical Rust Worker/D1 API proof
pnpm test:e2e

# Legacy Node/APNs unit regression, migration diagnostics only
pnpm test:unit

# Paperclip stdio boundary and same-session smoke
pnpm test:paperclip

# Canonical Rust Worker/D1 API contract smoke
pnpm test:e2e

# Legacy Node API regression, migration diagnostics only
pnpm test:e2e:node

# Canonical Codex host → same-session safe decision → result
pnpm test:canonical:codex

# RC auth/security/history/metrics smoke
pnpm test:rc
pnpm test:security

# Codex/Cursor/Paperclip installer smoke (uses a temporary home)
pnpm test:installer

# iOS model decoding / iOS 15 compatibility regression (XcodeBuildMCP or Xcode)
cd apps/ios && xcodebuild test \
  -scheme VoiceAgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation),OS=17.5'

# Full iOS Simulator regression: verify the Rust Worker, generate the project,
# then run 36 unit tests + 3 UI tests. Each UI test creates its own account,
# agent, session, and `needs_user` fixture, so no MCP agent key is required.
# Override `BRIDGE_API_URL` and `IOS_TEST_DESTINATION` when needed.
pnpm test:ios

# Terminal C — iOS Simulator UI
cd apps/ios && xcodegen generate && xcodebuild \
  -scheme VoiceAgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
# then Run from Xcode (⌘R) or `xcrun simctl launch ...`

# Physical-device sign-off (after unlocking Mac + iPhone)
pnpm signoff:phone

# Watch the exact fresh session and finish the agent claim/result automatically
pnpm signoff:phone:watch
# Or resume a session already emitted by signoff:phone
PHYSICAL_SESSION_ID=ses_… pnpm signoff:phone:watch

# Real physical two-turn flow: two decisions on one session/chat
pnpm signoff:phone:multiturn

# Paperclip integration notes and governed stdio MCP configuration
open docs/PAPERCLIP.md
```

## Opt-in physical voice production path

The real voice test is intentionally excluded from normal CI and Simulator runs. It
requires a connected iPhone, a backend that reports `knock_knock_model_enabled 1`,
and the public key for the backend's signed model manifest. It validates the production
model manager, push-to-talk, on-device transcription/intent generation, REST/SSE
reconciliation, and the exact backend-owned `history_search.completed` presentation.

```bash
./scripts/ios-physical-voice-e2e.sh \
  --device 741C39D8-8BFE-5E63-A06A-E194F3E0E5A2 \
  --api-base https://knock-knock-backend-staging.wch-klaus.workers.dev \
  --public-key /absolute/path/public-key.base64
```

For an explicit local Worker started with `--test-scheduled`, add only a loopback
scheduled endpoint:

```bash
  --scheduled-url http://127.0.0.1:8787/__scheduled
```

The script never deploys or changes backend configuration. It fails before building when
the model is disabled. When the test prints `SPEAK NOW`, say **“Show me what happened
today”**, keep holding through at least one second of silence, and then confirm that the
phone audibly says **“History search completed.”** First-use microphone and Speech
Recognition permission prompts remain human-controlled. The retained `.xcresult` contains
the model-ready and backend-result screenshots; DerivedData is removed automatically.

The test's success oracle is the final backend message, not a local queued or optimistic
state. Raw microphone buffers stay in memory and are appended only to the on-device speech
request; the app has no audio upload API and does not write an audio recording.

## Voice Dataset v2 deterministic UAT

Keep the dataset and all generated audio outside Git. A configured package is rejected
unless it contains 48 examples, 144 manifest rows, 144 unique paths, 144 unique content
hashes, valid PCM signed 16-bit 16 kHz mono WAV data, matching hashes/durations, no hard
clipping, and the frozen safety gates.

The received 2026-08-12 package had only 114 unique hashes because every English clean
file shared one recording and every English fast-phone file shared another. Its manifest
also declared only one voice ID for every locale. Regenerate a normalized external copy
without changing the original package:

```bash
scripts/regenerate-voice-dataset-v2-local.sh \
  /absolute/path/to/normalized-input \
  /absolute/path/to/new-repaired-output
```

The local generator uses two native voices for English and Mandarin. It calibrates each
pink-noise profile from measured clean/noise RMS energy and rejects any generated WAV
outside the 14-16 dB SNR window; the Swift integrity test independently measures the PCM
difference against the clean reference. macOS currently
exposes only `Sinji` as a native Hong Kong Cantonese voice, so every Cantonese manifest
row records that explicit provider-limitation exception. The exact macOS/FFmpeg provenance
and transforms are recorded in the manifest. Validate the external package on Simulator:

```bash
cd apps/ios
xcodegen generate
KNOCK_VOICE_AUDIO_DATASET_ROOT=/absolute/path/to/repaired-output \
xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:VoiceAgentBridgeTests/VoiceAudioDatasetV2Tests \
  test
```

Stage only the validated JSON, manifest, and WAV files to the app's test Documents
directory on an unlocked iPhone:

```bash
scripts/ios-voice-audio-uat.sh \
  --device "$KNOCK_DEVICE_UDID" \
  --dataset-root /absolute/path/to/repaired-output
```

The opt-in STT gate feeds each WAV through `SystemOnDeviceSpeechTranscriber`; the full
Layer A gate then selects the same command runtime as production and applies the strict
envelope policy. iPhone 13 Pro/Pro Max use the deterministic parser and do not require a
staged model; newer Gemma devices require the staged signed artifact. The machine report
records the selected runtime and version. Start with one clean sample, then the 12-ID human
subset, then all profiles. Speech Recognition permission remains human-controlled and an
unauthorized device fails closed.

```bash
cd apps/ios
xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge \
  -destination "platform=iOS,id=$KNOCK_DEVICE_UDID" \
  -only-testing:VoiceAgentBridgeTests/VoiceAudioSTTEvaluationTests \
  KNOCK_RUN_VOICE_AUDIO_STT_UAT=1 \
  KNOCK_VOICE_AUDIO_LIMIT=1 \
  KNOCK_VOICE_AUDIO_PROFILES=clean_normal \
  KNOCK_VOICE_RESULT_DEVICE=iphone13-pro \
  test

xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge \
  -destination "platform=iOS,id=$KNOCK_DEVICE_UDID" \
  -only-testing:VoiceAgentBridgeTests/VoiceAudioPipelineEvaluationTests \
  KNOCK_RUN_VOICE_AUDIO_PIPELINE_UAT=1 \
  KNOCK_VOICE_AUDIO_PROFILES=clean_normal,fast_phone,noise_snr15 \
  KNOCK_VOICE_RESULT_DEVICE=iphone13-pro \
  test
```

Machine-readable STT and pipeline results are written below the staged package's
`voice-golden-v2-generated/results/` directory. No test creates an API client or uploads
audio. Backend idempotency and confirmation remain a separate Layer B gate.

### iPhone 13 runtime policy

`iPhone14,2` (iPhone 13 Pro) and `iPhone14,3` (iPhone 13 Pro Max) use the
fail-closed `DeterministicCommandGenerator`. The rejected 270M model is never loaded on
these devices. The parser recognizes only the four allowlisted command shapes, grounds
arguments in the transcript, and emits the same strict `CommandEnvelope` used by the
signed Gemma path. Unsupported, incomplete, negated, compound, or policy-override
utterances require clarification. Newer supported devices continue to use the signed,
runtime-probed Gemma artifact.

The transcript-level Dataset v2 gate validates all 48 commands against this iPhone 13
policy. Physical WAV UAT remains separate because it also measures Apple's local STT,
latency, device temperature, memory pressure, and the complete push-to-talk lifecycle.

`pnpm test:canonical:codex:multiturn` creates two idempotent events, resumes the
same session between them, and verifies two distinct action results with one
`chat_id`. `pnpm test:ios` uses `scripts/ios-test-fixture.sh`; the fixture creates a
unique session and idempotency key every run and refuses to run against the
legacy Node API.

Production configuration must set a random `JWT_SECRET` (at least 32
characters), an HTTPS `PUBLIC_BASE_URL`, one explicit `CORS_ORIGIN`, and
`PUSH_MODE=apns` or `both`.
The checked-in `.env.example` intentionally keeps development defaults for
the local Mac/iPhone loop.

## Current release-candidate gates

- [x] Rust Worker is the production source of truth and passes contract, Paperclip,
  canonical Codex multi-turn, and RC security smokes.
- [x] Production Worker is deployed at the HTTPS endpoint configured by the iOS Release
  target; health and metrics checks pass.
- [x] Build25 (the account-first release candidate) is archived with official Apple
  Distribution signing and production APNs entitlement, and uploaded to App Store Connect.
- [ ] Build25 finishes App Store processing and is installed on the iPhone 13 Pro.
- [ ] User creates the production account with a self-chosen password and signs in on the
  phone; no password is stored in the repository or accessible to automation.
- [ ] The final real-phone two-turn flow is observed after the new production account is
  paired to the canonical Codex host.
- [ ] Cloudflare API token is added as a GitHub Actions secret so the daily D1 backup
  workflow can run; the account ID and other non-secret repository variables are ready.

## MCP host smoke (after pair)

```bash
# From phone user session, create pairing code in App or:
curl -s -X POST http://127.0.0.1:8787/v1/pairing/code \
  -H "Authorization: Bearer $USER_TOKEN"

vab pair --code XXXXXX --label "codex-mac" --write-env .env.agent
# configure Cursor/Codex MCP with BRIDGE_AGENT_KEY
```

## Definition of Done (MVP)

- [x] Rust Worker/D1 contract smoke passes via `pnpm test:e2e`
- [x] Simulator login + session list shows progress without push
- [x] Simulator receives needs_user via dev inbox and completes destructive confirm
- [x] iOS model decoding tests pass for session, push, and pending-action payloads
- [x] Build-18 simulator full scheme passes 4 model tests + 2 UI tests
- [x] Same agent key works from the MCP stdio server against local API
- [x] `pnpm test:paperclip` verifies the local five-tool stdio boundary and same-session resume/reply/result retry
- [x] Physical Build-9 completes a fresh knock → destructive confirm → agent result loop
- [x] Historical physical Build-11 completes a fresh knock → destructive confirm → agent result loop
- [x] Current connected iPhone 13 Pro installs build-16 and repeats the same loop
- [x] Current connected iPhone receives a sandbox APNs notification; system log records user-visible delivery
- [x] Current iPhone 13 Pro installs build-17 and repeats the same loop
- [x] Build-18 production UI compiles, installs, and launches on the current iPhone 13 Pro
- [x] Build-18 Simulator loop covers knock → review → destructive confirmation → alternate action → queued → agent result
- [ ] Build-18 physical knock → destructive confirmation → agent result loop (the iOS 26.6 Beta UI automation service timed out before test execution; manual phone taps or a matching Xcode beta remain)
- [x] Build-19 physical two-turn knock → destructive confirmation → follow-up decision → agent result loop stays on one session/chat
- [ ] Cursor and Codex each complete one scripted loop (manual checklist)
- [x] Paperclip connection boundary documented; hosted Paperclip smoke remains a manual check when a Paperclip instance is available
- [x] RC installer covers Codex, Cursor, and Paperclip without overwriting host configs
- [x] Refresh-token rotation, scoped Agent-key rotation, audit history, metrics endpoint, production HTTPS/APNs config, and iOS archive script are implemented

Physical-device sign-off: connect and unlock the iPhone 13 Pro, then run
`pnpm signoff:phone` (or set `KNOCK_DEVICE_UDID` explicitly). It verifies the API, LAN
address, installed expected build, and launch before emitting a fresh
knock. Then tap **Review request**, choose an action, confirm if required, and run the
MCP `pending`/`result` commands.

Perform the final taps on the unlocked iPhone; Mac automation can install, launch, inspect
device logs, and complete the agent-side claim/result. If using Xcode UI automation instead,
use an Xcode beta with an SDK/automation service matching the iPhone's iOS 26.6 Beta.

For a hands-off agent-side completion after the human tap, use
`pnpm signoff:phone:watch`; it claims the selected action and submits an approval or
phone cancellation result, but it cannot replace the human observation of the physical
in-app popup and system banner.

`pnpm signoff:phone:multiturn` extends this to two sequential decisions. It proves
that the agent resumes the same `session_id` and `chat_id` after the first result;
both phone decisions still require human taps.
