# iPhone 13 Pro Voice Command UAT

Updated: 2026-08-12 (Asia/Hong_Kong)

## Purpose

Prove the production path on an iPhone 13 Pro:

```text
real speech → local STT → deterministic intent/argument parser
→ strict CommandEnvelope → local safety reconstruction
→ authenticated backend validation/execution
→ result or explicit confirmation in the app
```

The release claim requires real-device evidence. Simulator or synthetic-text
results are supporting evidence only and must not be reported as physical voice UAT.

## Approved device policy

- `iPhone14,2` (iPhone 13 Pro) and `iPhone14,3` (iPhone 13 Pro Max) use
  `DeterministicCommandGenerator` version `deterministic-rules-1.0.0`.
- The rejected Gemma 3 270M candidate is not loaded on either device.
- The parser recognizes only `search_history`, `create_reminder`, `create_draft`,
  and `send_message`.
- Every argument must be grounded in the local transcript. Missing, ambiguous,
  negated, compound, unsupported, or policy-override requests clarify.
- `send_message` is rebuilt as high risk with confirmation required. Neither the
  STT output nor a local parser can weaken backend authority.
- Newer supported devices continue to use the signed, runtime-probed Gemma path.

## Current evidence

| Gate | Evidence | State |
|---|---|---|
| Dataset structure | 48 examples, 144 WAVs, 144 unique hashes, PCM 16-bit/16 kHz/mono | Passed |
| Noise profile | Every `noise_snr15` WAV is independently measured against its clean reference and must be 14–16 dB | Passed |
| Transcript policy simulation | 36/36 commands, 12/12 clarifications, 1.000 per locale, high-risk false executions 0 | Passed, non-physical |
| Parser latency simulation | p50 291 µs, p95 898 µs on the current Simulator run | Informational only |
| iOS regression | 192 tests: 187 passed, 0 failed, 5 opt-in physical/model tests skipped | Passed |
| arm64 iOS build | Generic physical-device Debug build | Passed |
| Raw-audio privacy boundary | Capture requires on-device recognition, appends buffers directly to `SFSpeechAudioBufferRecognitionRequest`, has no file/network dependency, removes the input tap, ends audio, cancels recognition, and releases handlers during cleanup | Passed by source/runtime-boundary audit; physical observation still pending |
| Backend authority | Command isolation, idempotency, confirmation, paging, and execution-time authority gates | Passed separately |
| One-WAV physical STT | Xcode cannot launch while the phone is locked; Speech/Microphone permission is human-controlled | Pending |
| Full physical audio pipeline | 1 clean → 12-ID subset → all 144 profiles | Pending |
| Live push-to-talk/VAD | Real microphone, stop/final transcript, clarification, confirmation, result/TTS | Pending |
| Stability | memory, thermal, repeated commands, interruption/cancellation | Pending |
| Offline and two-device convergence | airplane-mode recovery and simultaneous same-account devices | Pending |

The transcript-policy machine report is generated as
`voice-golden-v2-generated/results/iphone13-pro-transcript-policy-results.json`.
The physical pipeline report must be generated as
`voice-golden-v2-generated/results/iphone13-pro-pipeline-results.json`; it records
`runtime_strategy=deterministic_parser` so results cannot be confused with Gemma UAT.

## Physical execution order

1. Human unlocks the iPhone 13 Pro, opens Knock Knock, and grants Microphone and
   Speech Recognition permission. Keep the phone awake and connected to the Mac.
2. Run one `clean_normal` WAV. Stop immediately if STT or locale initialization fails.
3. Run the 12-ID core subset, then inspect per-locale failures and timing.
4. Run all 48 examples across `clean_normal`, `fast_phone`, and `noise_snr15`.
5. Use the live push-to-talk UI for English, Simplified Chinese, and Cantonese.
6. Verify ambiguous/unsafe utterances clarify and never create a backend command.
7. Submit the same safe command twice with the same idempotency identity and prove one
   backend side effect. Confirm a high-risk command once and prove replay is rejected.
8. Repeat after airplane mode and app termination; then verify convergence with the
   second signed-in physical phone.

Expected elapsed time after the phone is unlocked and authorized:

- one-WAV smoke: 5–10 minutes
- 12-ID subset: 20–40 minutes
- all 144 profiles and report review: 1–2 hours
- live PTT/VAD, interruption, thermal, and stability: 45–75 minutes
- offline and two-device convergence: 30–60 minutes when both phones are present

## Release gates

- overall command semantic accuracy at least 0.95
- each locale command accuracy at least 0.90
- clarification recall at least 0.95
- high-risk false executions exactly 0
- no duplicate side effect for an idempotent replay
- no microphone buffer or raw user recording persisted or uploaded
- only the validated `CommandEnvelope` may cross the authenticated command API boundary;
  the active-command journal intentionally excludes audio and transcripts
- no merge or production rollout based only on transcript simulation

Implementation and evidence are tracked in
[frontend Draft PR #20](https://github.com/wchklaus97/knock-knock-frontend/pull/20).
