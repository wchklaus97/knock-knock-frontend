# iPhone 13 Pro Voice Command UAT

Updated: 2026-08-13 (Asia/Hong_Kong)

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
| iOS regression | 193 tests: 186 passed, 0 failed, 7 opt-in physical/model tests skipped on iOS 17.5 Simulator | Passed |
| arm64 iOS build | Generic physical-device Debug build | Passed |
| Raw-audio privacy boundary | Capture requires on-device recognition, appends buffers directly to `SFSpeechAudioBufferRecognitionRequest`, has no file/network dependency, removes the input tap, ends audio, cancels recognition, and releases handlers during cleanup | Passed by source/runtime-boundary audit; physical observation still pending |
| Backend authority | Command isolation, idempotency, confirmation, paging, and execution-time authority gates | Passed separately |
| Legacy one-WAV physical STT | `clarify-en-01`, exact transcript, edit distance 0, 346 ms on iPhone 13 Pro / iOS 26.6 | Passed |
| Legacy 12-WAV physical STT | 12/12 returned final transcripts; English 35/37 units correct (94.6%), Cantonese 56/75 (74.7%), Simplified Chinese 14/71 (19.7%) | Failed accuracy gate |
| Legacy 12-WAV physical pipeline | 2/9 commands exact, 3/3 clarifications, high-risk false executions 0, p95 total 577 ms | Failed semantic gate; safe failure |
| SpeechAnalyzer one-WAV physical STT | `clarify-en-01`, exact transcript, edit distance 0, 605 ms | Passed |
| SpeechAnalyzer 12-WAV physical STT | 12/12 final; English 37/37 (100%), Cantonese 65/75 (86.7%), Simplified Chinese 55/71 (77.5%); per-locale p95 405/482/354 ms | Failed per-locale accuracy gate |
| SpeechAnalyzer 12-WAV physical pipeline | 3/9 commands exact, 3/3 clarifications, high-risk false executions 0, p95 STT 379 ms and p95 total 380 ms | Failed semantic gate; safe failure |
| DictationTranscriber comparison | English 35/37 (94.6%), Cantonese 56/75 (74.7%), Simplified Chinese 51/71 (71.8%); per-locale p95 438/785/660 ms | Rejected; worse than SpeechTranscriber |
| WhisperKit tiny comparison | English 94.6%, Cantonese 45.3%, Simplified Chinese 45.1%, p95 inference 278 ms | Rejected; multilingual accuracy failed |
| WhisperKit base comparison | English 94.6%, Cantonese 45.3%, Simplified Chinese 47.9%, p95 inference 418 ms | Rejected; multilingual accuracy failed |
| Full physical audio pipeline | All 144 profiles | Blocked by failed 12-WAV gate |
| Live push-to-talk/VAD | Real microphone, stop/final transcript, clarification, confirmation, result/TTS | Pending |
| Stability | memory, thermal, repeated commands, interruption/cancellation | Pending |
| Offline and two-device convergence | airplane-mode recovery and simultaneous same-account devices | Pending |

The transcript-policy machine report is generated as
`voice-golden-v2-generated/results/iphone13-pro-transcript-policy-results.json`.
The physical pipeline report must be generated as
`voice-golden-v2-generated/results/iphone13-pro-pipeline-results.json`; it records
`runtime_strategy=deterministic_parser` so results cannot be confused with Gemma UAT.

The 12-WAV run exposed a locale interoperability issue. Dataset locale identifiers
`zh-Hans-HK` and `yue-Hant-HK` are not directly advertised by Speech on the test
device. Production now resolves Simplified Mandarin to `zh-CN` and Hong Kong
Cantonese to the first on-device-capable candidate among `yue-HK`, `yue-CN`, and
`zh-HK`. This changes availability, not the accuracy gate.

An iOS 26-only qualification adapter also exercised `SpeechAnalyzer` against the
same physical files. Automatic mode selected `SpeechTranscriber` and improved both
Chinese languages substantially, but still missed the 90% per-locale release gate
and reached only 3/9 exact commands. Forced `DictationTranscriber` was slower and
less accurate, including a one-time asset-install delay, so it is not a release
candidate. The qualification adapter is deliberately file-only: it does not replace
the live push-to-talk capture path, persist audio, or upload audio. Full 144-file and
live migration work remain blocked until an STT backend passes the 12-file gate.

The current official WhisperKit package requires iOS 16, while the frozen app floor
is iOS 15. Adopting it therefore requires an explicit deployment-floor decision (or
a separately isolated runtime target) before package integration. Local APFS free
space was approximately 15 GiB during qualification, so model downloads and derived
data must be budgeted and cleaned deliberately.

An isolated iOS 16 test bundle subsequently qualified WhisperKit `tiny` and `base`
without changing or linking the production iOS 15 app target. Both ran quickly but
failed the multilingual accuracy gate, so neither advances to production. Full data
and reproduction commands are recorded in `WHISPERKIT_IPHONE13_BENCHMARK.md`.

The external package also has inconsistent provenance: `package_readme.md` says
Mandarin and Cantonese were generated through MiniMax, while the signed manifest
records Apple `say` on macOS 26.5.2. The regenerated `draft-zh-01` Apple `say` WAV
matches the package SHA-256 exactly, so the manifest is the observed source of
truth; the package cannot be accepted as formal release-provenance evidence until
its handoff documentation is corrected.

## Physical execution order

1. Human unlocks the iPhone 13 Pro, opens Knock Knock, and grants Microphone and
   Speech Recognition permission. Keep the phone awake and connected to the Mac.
2. Run one `clean_normal` WAV. Stop immediately if STT or locale initialization fails.
3. Run the 12-ID core subset, then inspect per-locale failures and timing. Stop if
   any release gate fails.
4. Run all 48 examples across `clean_normal`, `fast_phone`, and `noise_snr15` only
   after the core subset passes.
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
