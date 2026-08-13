# Voice Command Safety Gate — 2026-08-13

## 中文摘要

本轮把语音命令验收固定为四个不可降低的安全条件：命令必须由 Backend
持久化；同一个 envelope 重试不得创建第二条命令或重复外部副作用；高风险
命令必须停在确认状态；人名、时间或金额不确定时只能追问，不能提交命令。

自动化门禁已通过。真人 iPhone 13 Pro 录音门禁仍未完成：最近一次运行在
120 秒内没有检测到手动按压，因此安全失败且没有创建命令。按照既定顺序，
iPhone 17 Pro Max 必须等待 iPhone 13 Pro 真人门禁通过后再运行。36+ 真人
语音协议和校验器已经建立，但真实语料本身尚未达到 36 条和每种语言三位
说话者的要求。

## Frozen safety contract

1. A locally generated `CommandEnvelope` is written to SQLite before POST.
2. The canonical Rust Worker persists and returns the command by `command_id`.
3. Replaying the exact `command_id`, `idempotency_key`, and envelope returns the
   same canonical command and does not add another command.
4. Provider execution uses a scoped idempotency key and a durable action-attempt
   record. A successful attempt is reused instead of repeated.
5. `send_message` is always rebuilt as high risk and remains
   `awaiting_confirmation` until a one-time Backend token is consumed.
6. Uncertain person, time, or amount input produces clarification and zero POSTs.

## Verified evidence

### Backend

- Baseline: `83e3c6c21a8bd8149d84e83b07c45778676a8678` (`main`).
- `scripts/local-contract-gate.sh`: passed against isolated local Worker/D1/R2.
- `scripts/provider-local-gate.sh`: passed, including one provider delivery after
  exact duplicate command replay.
- Staging contract run: [GitHub Actions 31707781688](https://github.com/wchklaus97/knock-knock-backend/actions/runs/31707781688), passed on the same baseline.
- Staging is intentionally fail-closed for external effects:
  `action_provider_ready=false`. The staging run proves persistence,
  isolation, idempotency, pagination, and confirmation behavior; it does not
  claim a real external message was delivered.

### iOS automated gates

- Baseline: `27517b013b43ee64767fbe9337f386ad3baf5fdd` (`main`, after PR #26).
- Full iOS Simulator regression: 206 unit tests, 9 skipped, 0 failures.
- UI regression: 6 UI tests, 3 opt-in physical tests skipped, 0 failures.
- Explicit uncertain-slot test: person, time, and amount examples in `en-HK`,
  `zh-Hans-CN`, and `yue-Hant-HK` all required clarification; 9 cases in one
  test, 0 failures.
- Cold-start retry test: a lost/404 status lookup replays the exact persisted
  `CommandEnvelope`, including the same command and idempotency identifiers.
- Fresh arm64 Simulator `build-for-testing`: passed for the app, unit tests, and
  UI-test target after the physical UAT harness changes.
- The physical UAT harness now supports three independent expectations:
  `history`, `high-risk`, and `clarification`.
- The harness refuses Production or arbitrary HTTPS origins, requires
  pre-granted microphone/speech permissions, and requires
  `action_provider_ready=false` before a high-risk test.

## Physical-device gate status

| Gate | iPhone 13 Pro | iPhone 17 Pro Max |
|---|---|---|
| Low-risk voice command persists | Pending human run | Blocked by ordered gate |
| Exact replay adds no command | Pending human run | Blocked by ordered gate |
| High-risk waits for confirmation | Pending human run | Blocked by ordered gate |
| Ambiguity produces zero POSTs | Pending human run | Blocked by ordered gate |

The latest iPhone 13 Pro attempt prepared the Staging app and safe-parser runtime,
then timed out because no manual press reached `Listening`. The harness failed
closed before any command assertion. This is recorded as an incomplete operator
run, not a product pass or product failure.

## Human corpus gate

`scripts/validate-human-voice-corpus.sh` structurally validates an external,
non-symlink corpus containing at least 36 unique declared-human recordings:

- at least 12 each for `en-HK`, `zh-Hans-CN`, and `yue-Hant-HK`
- at least three opaque speakers per locale and four recordings per speaker
- all four command intents in every locale
- unique sample IDs, file paths, and SHA-256 content hashes
- at least one uncertain-person, uncertain-time, and uncertain-amount
  clarification example per locale
- canonical expected intent, arguments, risk, and confirmation behavior
- exact audio inventory, decodable WAV/M4A metadata, and semantic RFC 3339 time

Software cannot prove that audio is human or exclude TTS/replay. Passing also
requires an explicit human provenance, consent, distinct-speaker, and privacy
review. The validator refuses a normal run unless that review is attested; PR
evidence remains aggregate-only and never includes raw audio or the manifest.

The validator's self-test passes one structural fixture and confirms rejection
of manifest replacement, duplicate rows, fake audio, missing intent coverage,
an invalid 10/1/1 speaker distribution, an impossible timestamp, and extra
unmanifested audio.

The current 12-file, one-speaker pilot remains useful diagnostic evidence but
cannot pass this release gate. Synthetic MiniMax/ElevenLabs audio cannot be
counted as human evidence.

## Remaining operator sequence

1. Run iPhone 13 Pro `history`, `high-risk`, and `clarification` modes with a
   human speaking the printed phrase.
2. Only after all three pass, repeat them on iPhone 17 Pro Max with signed Gemma.
3. Collect at least 24 additional consented recordings so the external corpus
   reaches the 36-file, three-speaker-per-locale minimum.
4. Run the corpus validator and production-selected STT-to-CommandEnvelope UAT.
5. Keep the PR draft until the physical and corpus evidence is attached.
