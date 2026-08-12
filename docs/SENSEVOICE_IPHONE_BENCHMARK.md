# SenseVoiceSmall Cantonese INT8 iPhone Qualification

Updated: 2026-08-13 (Asia/Hong_Kong)

## Decision

**Reject this model for Knock Knock STT and do not ship it to staging or
production.** It is fast and runs fully offline, but it fails every language
accuracy gate and corrupts command verbs, names, project names, and numbers.
Faster hardware improves latency but produces the same transcripts.

The experiment is isolated in `VoiceAgentBridgeSenseVoiceTests` and the
`VoiceAgentBridgeSenseVoiceQualification` scheme. The production app target does
not link sherpa-onnx or ONNX Runtime, and no model or test audio is committed.

## Artifact and runtime

| Item | Value |
|---|---|
| Runtime | sherpa-onnx Swift package 1.13.5 |
| Runtime license | Apache-2.0 |
| Model | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09` |
| Archive size | 165,783,878 bytes |
| Archive SHA-256 | `7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63` |
| `model.int8.onnx` size | 237,115,547 bytes |
| ONNX SHA-256 | `12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d` |
| `tokens.txt` size | 315,894 bytes |
| tokens SHA-256 | `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc` |
| Runtime assets | 237,431,441 bytes (about 226.4 MiB) |

The sherpa-onnx runtime and the WSYue-ASR source model declare Apache-2.0.
The converted release archive does not include a standalone model license, and
SenseVoice/FunASR may carry additional model terms. A future redistribution
candidate still requires legal/compliance review; local evaluation does not
grant App Store redistribution rights.

Sources:

- <https://github.com/k2-fsa/sherpa-onnx>
- <https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models>
- <https://huggingface.co/ASLP-lab/WSYue-ASR>

## Dataset and method

The same consented Hong Kong speaker recorded four English, four Mandarin, and
four Cantonese commands. The set covers reminder, draft, high-risk message, and
unsafe/prompt-injection clarification cases. The speaker self-reported limited
English and Mandarin proficiency; this is a realistic accented-user safety test,
not a population benchmark.

Original M4A files remained outside the repository. Temporary copies were
converted to PCM signed 16-bit, 16 kHz, mono. The recognizer ran with two CPU
threads, inverse text normalization, and no network dependency. Accuracy is WER
for English and character edit accuracy for Chinese. Tests used both forced
language and automatic language modes.

## Physical-device STT results

Forced language mode:

| Device | `en-HK` | `zh-Hans-HK` | `yue-Hant-HK` | Overall p95 | Weighted STT accuracy |
|---|---:|---:|---:|---:|---:|
| iPhone 13 Pro (`iPhone14,2`) | 48.8% / 299 ms | 84.1% / 242 ms | 48.0% / 204 ms | 299 ms | 61.5% |
| iPhone 17 Pro Max (`iPhone18,2`) | 48.8% / 236 ms | 84.1% / 201 ms | 48.0% / 153 ms | 236 ms | 61.5% |

Automatic language mode:

| Device | `en-HK` | `zh-Hans-HK` | `yue-Hant-HK` | Overall p95 | Load | Resident-memory increase |
|---|---:|---:|---:|---:|---:|---:|
| iPhone 13 Pro | 48.8% / 301 ms | 82.6% / 242 ms | 48.0% / 199 ms | 301 ms | 717 ms | about 320.7 MiB |
| iPhone 17 Pro Max | 48.8% / 235 ms | 82.6% / 228 ms | 48.0% / 153 ms | 235 ms | 502 ms | about 322.7 MiB |

Automatic mode labelled every sample as Cantonese (`<|yue|>`), including all
English and Mandarin recordings. Representative critical errors included:

- `10:30` becoming “ten firty”;
- `fifteen` becoming “fifty”;
- `Alex` becoming `AEX`, `ALICE`, or `IH`;
- `Orion` becoming `RIAN`, `OIN`, `OIE`, or unrelated Chinese words;
- command verbs such as “draft”, “tell”, and “ignore” being corrupted.

## End-to-end safety simulation

The 12 automatic-mode transcripts were passed only to the existing local
fail-closed deterministic parser. This test did not instantiate an API client,
contact the backend, or execute an action.

| Metric | Required | iPhone 13 Pro | iPhone 17 Pro Max |
|---|---:|---:|---:|
| Per-language STT accuracy | >=90% | Fail all 3 | Fail all 3 |
| Correct command envelopes | >=95% | 0/9 (0%) | 0/9 (0%) |
| Correct outcomes including clarification | >=95% | 3/12 (25%) | 3/12 (25%) |
| High-risk false executions | 0 | 0 | 0 |
| STT p95 | <=2,000 ms | 301 ms | 235 ms |
| Offline | required | Pass | Pass |
| Raw-audio upload | forbidden | Pass | Pass |

All three unsafe/unsupported samples correctly became clarification. Corrupted
message commands also failed closed. Two corrupted reminder transcripts still
produced mismatched command arguments in the isolated simulation. Because the
STT release gate fails first, none of these transcripts are eligible for Gemma
or backend submission.

## Comparison with the prior WhisperKit base run

| Model / device | English | Mandarin | Cantonese | Overall p95 | Decision |
|---|---:|---:|---:|---:|---|
| WhisperKit base / iPhone 13 Pro | 34.9% | 42.0% | 41.3% | 348 ms | Reject |
| SenseVoice INT8 / iPhone 13 Pro | 48.8% | 82.6% | 48.0% | 301 ms | Reject |
| WhisperKit base / iPhone 17 Pro Max | 37.2% | 42.0% | 40.0% | 242 ms | Reject |
| SenseVoice INT8 / iPhone 17 Pro Max | 48.8% | 82.6% | 48.0% | 235 ms | Reject |

SenseVoice materially improves Mandarin and remains fast, but it is far below
the 90% per-language safety floor and cannot reliably preserve critical slots.

## Reproduction and cleanup

1. Build/install the isolated scheme on the selected physical device.
2. Verify the published archive and ONNX SHA-256 values above.
3. Stage only `model.int8.onnx`, `tokens.txt`, the validated Dataset v2 JSON,
   and explicitly consented PCM copies under
   `Documents/KnockKnockSenseVoiceUAT`.
4. Run `testConfiguredFilesTranscribeOnPhysicalDevice` with
   `KNOCK_RUN_SENSEVOICE_UAT=1`, an explicit comma-separated file list, and
   `KNOCK_SENSEVOICE_LANGUAGE=auto`, `en`, `zh`, or `yue`.
5. Run `testDeleteStagedSenseVoiceDataAfterUAT` with
   `KNOCK_SENSEVOICE_DELETE_UAT_DATA=1`.

The build/install step must precede staging because Xcode may replace the test
host container. Cleanup deletes only the exact UAT directory and a guarded
legacy staging layout whose Dataset v2 marker matches the expected dataset ID.
Both physical devices were checked after cleanup; neither UAT path remained.

## Rollback

No production code path or model distribution was enabled. Reverting this
experiment consists of removing the SenseVoice qualification target, scheme,
test source, and sherpa-onnx package declaration. No backend, D1, R2, staging,
or production rollback is required.

## Next architecture gate

Do not use SenseVoice as a unified push-to-talk model. The later same-corpus
comparison qualifies it only for the Mandarin branch of an explicit language
router. Cantonese uses Apple SpeechAnalyzer; English uses Apple with strict
clarification because it remains slightly below the release gate. The
SenseVoice production adapter still requires signed-model startup, lifecycle,
memory, and command-safety qualification before it can be enabled.

## Public-corpus follow-up

A later 120-clip, multi-speaker public benchmark showed that the original
single-speaker recordings materially underestimated Mandarin and Cantonese
recognition. SenseVoice reached 97.9% Mandarin accuracy and 90.6% Cantonese
accuracy after script normalization, but only 71.8% Hong Kong English accuracy.
The two devices produced identical transcripts. This does not reverse the
unified-model rejection or the command-safety result; it narrows SenseVoice to a
possible Mandarin/Cantonese routed adapter. Full provenance and methodology are
recorded in `docs/PUBLIC_STT_BENCHMARK.md`.
