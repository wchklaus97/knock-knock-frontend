# WhisperKit iPhone 13 Pro Qualification

Updated: 2026-08-13 (Asia/Hong_Kong)

## Scope

This is an isolated experiment, not a production STT migration. The production
`VoiceAgentBridge` target remains on iOS 15 and does not link WhisperKit. Only the
`VoiceAgentBridgeWhisperKitTests` bundle has an iOS 16 deployment target and links
`argmax-oss-swift` / WhisperKit 1.1.0.

The physical benchmark ran on iPhone 13 Pro (`iPhone14,2`) with iOS 26.6. Audio
was read from the existing synthetic Dataset v2 package in the app container. No
audio was persisted by the test or uploaded to the Knock Knock backend.

## Models and observed results

| Model | Published model size | First download/load | Warm load | English | Simplified Chinese | Cantonese | p95 inference | Decision |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Whisper tiny | 76.6 MB | 49.6 s | 13.1 s | 94.6% | 45.1% | 45.3% | 278 ms | Reject |
| Whisper base | 147 MB | 94.7 s | 16.6 s | 94.6% | 47.9% | 45.3% | 418 ms | Reject |

Both models loaded, ran locally, and stayed within the latency target. `base`
returned an empty transcript for one Cantonese sample. Neither model reached the
required 90% accuracy for every locale, so semantic command evaluation, live
push-to-talk migration, the 144-file run, and larger model downloads were stopped.

The very similar multilingual failure pattern across `tiny` and `base`, together
with the existing package provenance mismatch, indicates that the synthetic
Mandarin/Cantonese audio also needs validation with real human recordings. This
does not justify lowering any safety or release threshold.

## Real Cantonese follow-up

Four consented recordings from the user were mapped to the Dataset v2 human
subset (`reminder-yue-03`, `draft-yue-02`, `message-yue-03`, and
`clarify-yue-04`). The original M4A files remained outside the repository. Test
copies were converted to PCM 16-bit, 16 kHz, mono and staged only in the physical
device's app test container. Converted host copies and staged device copies were
deleted after the benchmark; the user's original M4A files were retained unchanged.

| Language mode | Accuracy | p95 inference | Decision |
|---|---:|---:|---|
| Forced Whisper `zh` | 37.3% | 591 ms | Reject |
| Automatic detection | 41.3% | 341 ms | Reject |

Automatic detection improved latency and a small amount of text accuracy, but
critical values such as `Alex`, `Orion`, time wording, and action verbs were still
misrecognized. Traditional-to-Simplified conversion also lowers the character
score, but does not explain the critical-parameter errors. The result shows that
the synthetic TTS provenance issue is not the only blocker for Whisper `base`.

Gemma is intentionally not evaluated on these erroneous transcripts. On iPhone 13,
the approved intent layer is the deterministic parser; Gemma 3 1B is assigned to
newer devices. Neither an LLM nor rules may guess a person, project name, date, or
action that STT did not reliably produce.

### iPhone 17 Pro Max speed comparison

The same four recordings, WhisperKit `base`, and automatic language detection
were then run on iPhone 17 Pro Max (`iPhone18,2`) with iOS 26.6. The first run
downloaded/prepared the model and is not used as the steady-state load result.

| Device | Warm load | p95 inference | Accuracy |
|---|---:|---:|---:|
| iPhone 13 Pro | 16.381 s | 341 ms | 41.3% |
| iPhone 17 Pro Max | 15.924 s | 243 ms | 40.0% |

On this small matched sample, iPhone 17 Pro Max reduced p95 inference latency by
approximately 29% and warm load time by approximately 3%. The one-character
accuracy difference is not meaningful. Faster hardware does not repair the
Cantonese transcription errors, so WhisperKit `base` remains rejected on both
devices. This is an STT comparison only; Gemma 3 1B remains a separate intent
parser for newer devices and was not used to alter these transcripts.

## Reproduction

Stage the validated Dataset v2 package first, then run one file:

```bash
cd apps/ios
xcodebuild -project VoiceAgentBridge.xcodeproj -scheme VoiceAgentBridge \
  -destination "platform=iOS,id=$KNOCK_DEVICE_UDID" \
  -only-testing:VoiceAgentBridgeWhisperKitTests/WhisperKitQualificationTests/testConfiguredFileTranscribesOnPhysicalDevice \
  KNOCK_RUN_WHISPERKIT_UAT=1 \
  KNOCK_WHISPERKIT_MODEL=tiny \
  KNOCK_WHISPERKIT_AUDIO_FILE=clarify-en-01__clean_normal.wav \
  test
```

Leave `KNOCK_WHISPERKIT_AUDIO_FILE` empty to run the 12-ID human subset. Use
`KNOCK_WHISPERKIT_MODEL=base` for the base comparison. The test prints per-sample
edit distance, locale accuracy, load time, and p95 inference time.

Multiple explicit files may be comma-separated. Set
`KNOCK_WHISPERKIT_LANGUAGE_MODE=auto` to compare automatic language detection;
the default is the forced dataset language mapping.

## Next gate

Do not integrate either model into the app. Record a small, consented human subset
covering English, Simplified Chinese, and Cantonese, validate transcripts and
provenance, then rerun `base`. Only a backend reaching at least 90% per locale may
advance to semantic and live push-to-talk testing.

The experiment downloads public model files from the upstream Hugging Face
repository. Production adoption additionally requires Knock Knock's signed model
manifest, hash verification, private distribution, startup probe, and rollback
policy; a successful experimental download is not a release trust decision.
