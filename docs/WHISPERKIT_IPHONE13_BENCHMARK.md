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

## Next gate

Do not integrate either model into the app. Record a small, consented human subset
covering English, Simplified Chinese, and Cantonese, validate transcripts and
provenance, then rerun `base`. Only a backend reaching at least 90% per locale may
advance to semantic and live push-to-talk testing.

The experiment downloads public model files from the upstream Hugging Face
repository. Production adoption additionally requires Knock Knock's signed model
manifest, hash verification, private distribution, startup probe, and rollback
policy; a successful experimental download is not a release trust decision.
