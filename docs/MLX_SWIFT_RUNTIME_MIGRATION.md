# Swift + MLX Local Runtime Migration

## 中文摘要

Knock Knock 的手机端本地推理目标固定为：

```text
Swift UI / Audio
  -> local STT
  -> MLX Swift multilingual memory retrieval
  -> rules + MLX Swift Gemma intent and argument extraction
  -> strict CommandEnvelope
  -> Rust Backend validation, idempotency, confirmation, and execution
```

手机端不再以 Rust Candle 为目标。Backend 继续使用 Rust，并且仍是权限、风险、用户归属、幂等和执行结果的唯一权威来源。

当前主 App 的最低版本仍是 iOS 15。Gemma 4 所需的最新版官方 MLX Swift LM 最低支持 iOS 17，所以模型实验只存在于独立的 iOS 17 qualification targets；在验证通过前，不提高主 App deployment target，也不替换正式规则路径。

## Decision

- Use Swift for the iOS application, audio pipeline, safety policy, and CommandEnvelope construction.
- Use one MLX runtime for both embedding inference and Gemma inference.
- Keep existing LiteRT integration as a rollback path until MLX reaches parity on both physical devices.
- Do not add Candle or a Rust FFI layer to the iOS application.
- Keep the Rust backend authoritative. Local models never execute actions directly.

## Pinned qualification stack

| Component | Pinned version/model | Reason |
|---|---|---|
| MLX Swift | `0.31.4` | Exact version required by the pinned native Gemma 4 runtime |
| MLX Swift LM | `3.31.4` | Official native Gemma 4 E2B support; qualification target only |
| Memory embedding | `intfloat/multilingual-e5-small` | Official MLXEmbedders registry entry; multilingual semantic retrieval |
| Rejected baseline | `mlx-community/gemma-3-1b-it-qat-4bit` | Preserved for reproducible comparison; not release-eligible |
| New candidate | `mlx-community/gemma-4-e2b-it-4bit` | Native official-registry candidate for iPhone 17 Pro Max qualification |

The main application does not link these packages. Updating the qualification runtime therefore does not raise the iOS 15 product floor.

## Isolation

`VoiceAgentBridgeMLXQualification` and `VoiceAgentBridgeGemma4Qualification` are separate test schemes. Gemma 4 runs in the dedicated `VoiceAgentBridgeGemma4Tests` target. MLX remains outside the production application target.

- Normal application builds do not link MLX yet.
- An `otool` check of the generated physical-device host app showed only the existing
  `CLiteRTLM` runtime; MLX resources and code were confined to the qualification test plug-in.
- Normal unit/UI test schemes do not run MLX qualification.
- Tests require explicit `KNOCK_RUN_MLX_BENCHMARK=1`.
- Tests accept local model directories only. They do not download models from the network.
- The Gemma 4 scheme fixes `KNOCK_MLX_GEMMA_MODEL_ID` to the allowlisted E2B model. Unknown model IDs or mismatched `config.json` model types fail the test.
- Simulator inference requires a second explicit diagnostic flag and labels its report as
  non-qualifying. Device release gates can only be satisfied by physical-iPhone reports.
- Synthetic command fixtures are used; user transcripts and raw recordings are not logged.

## Qualification gates

### Memory embedding retrieval

- Recall@1 across the multilingual memory benchmark: at least 90%.
- Per-language Recall@1 for `en-HK`, `zh-Hans-HK`, and `yue-Hant-HK`: at least 90%.
- p95 query embedding inference: at most 2 seconds.
- Record cold load time, warm p50/p95, top-one margin, and MLX active/cache/peak memory.
- Embeddings retrieve candidate memory only. They must not select an executable action or bypass clarification.

### Gemma extraction

- Gemma is asked for one allowlisted literal field per request, such as `reminder_title` or
  `message_recipient`. It does not generate intent, command IDs, idempotency keys, time, risk,
  confirmation, locale, timezone, model identity, or execution controls.
- Model output must pass the existing single-object parser. The transport may unwrap one exact
  `json` code fence, but must not search for, repair, or merge partial JSON.
- Trusted local code grounds arguments in the transcript, rebuilds policy fields, and the final
  envelope must pass `CommandEnvelope.decodeStrict`.
- Missing or uncertain person, time, amount, or message body must produce clarification.
- High-risk false execution: zero.
- Local code cannot call an action provider directly.
- Backend revalidates every field and confirmation requirement.

## Qualification evidence (2026-08-14)

These are small synthetic engineering benchmarks, not production accuracy claims.

| Device | Model/test | Result | Load | Warm p95 / generation | Peak MLX memory |
|---|---|---:|---:|---:|---:|
| iPhone 13 Pro | multilingual E5, 30 retrieval queries | Recall@1 30/30; each locale 10/10 | 1.867 s | 12.9 ms | 546 MB |
| iPhone 17 Pro Max | multilingual E5, 30 retrieval queries | Recall@1 30/30; each locale 10/10 | 1.266 s | 90.9 ms | 541 MB |
| iPhone 17 Pro Max | Gemma 3 1B, one reminder safety smoke | strict canonical envelope passed | 2.628 s | 1.786 s generation | 1,026 MB |
| iPhone 13 Pro | Gemma 3 1B, one reminder safety smoke | strict canonical envelope passed; latency gate failed | 4.388 s | 4.148 s generation | 1,026 MB |
| iPhone 17 Pro Max | Gemma 4 E2B, English controlled-field shard | 7/8 commands; 10/11 fields; 4/4 clarifications; rejected | 2.805 s | 0.770 s command p95 | 2,849 MB |

The first local-directory Gemma run repeated `<end_of_turn>` because constructing a generic local
`ModelConfiguration(directory:)` omitted the registry's extra EOS token. Qualification must set
`extraEOSTokens: ["<end_of_turn>"]`. With that setting, Gemma returned one argument object; local
grounding and policy code produced the final strict envelope.

The existing 32-case synthetic command fixture was then run as locale shards on iPhone 17 Pro Max
because a single physical-device test process was terminated at about 60 seconds. The original
prompt baseline was:

| Locale | Commands | Required clarifications | High-risk false executions | Command p95 | Gate |
|---|---:|---:|---:|---:|---|
| `en-HK` | 8/8 (100%) | 4/4 | 0 | 1.852 s | pass |
| `zh-Hans-HK` | 7/8 (87.5%) | 3/3 | 0 | 2.235 s | fail |
| `yue-Hant-HK` | 5/8 (62.5%) | 1/1 | 0 | 2.228 s | fail |

The failed Chinese cases were rejected closed. They did not create commands or external side
effects. Gemma copied prompt-template metadata into its JSON, and the strict key parser rejected
the result. A first shorter positive-only prompt removed those extra keys but copied placeholder
values for two English message cases, reducing English command accuracy to 6/8 (75%). That prompt
is rejected. A second bounded prompt candidate explicitly required replacing all placeholders and
forbade extra keys. Its physical iPhone 17 English shard achieved only 3/8 commands (37.5%), while
all 4/4 required clarifications remained correct, high-risk false execution remained zero, load
time was 2.949 seconds, and command p95 was 1.874 seconds. The model still emitted placeholder text
for reminder and message fields. Because English already failed the 95% gate, the Mandarin and
Cantonese shards were intentionally not run. The candidate was rejected and the committed prompt
baseline was restored; Gemma remains ineligible for production command generation.

### Controlled-field qualification (2026-08-14)

A stricter architecture then replaced the full argument-object request with independent,
allowlisted field requests. Each response must be exactly `{"value":"literal transcript
substring"}` or `{}`. Unknown keys, duplicate keys, wrong types, placeholders, ungrounded text,
pronouns used as people, and command/time text in the wrong field all fail to clarification.
Trusted code still owns intent, time parsing, risk, confirmation, identifiers, and the final
`CommandEnvelope`.

On the physical iPhone 17 Pro Max, an exact reminder smoke passed in 3.668 seconds and the raw
model field was verified as `call John`; deterministic grounding was not allowed to hide a wrong
field. The complete English shard then produced:

| Metric | Result | Required |
|---|---:|---:|
| Exact commands | 3/8 (37.5%) | >=95% |
| Exact raw fields | 6/11 (54.5%) | >=95% |
| Required clarifications | 4/4 | 4/4 |
| High-risk false executions | 0 | 0 |
| Load | 2.743 s | recorded |
| Command p95 | 1.768 s | <=2 s |
| Field p95 | 0.896 s | <=2 s |

The model met latency and safe-rejection requirements but failed semantic accuracy. A diagnostic
without field examples became worse: 0/8 exact commands and 3/11 exact fields. That variant was
discarded. Mandarin and Cantonese were not run because failure of the English shard already blocks
qualification.

### Gemma 4 E2B qualification candidate (2026-08-14)

Gemma 4 is an isolated replacement experiment, not a production migration. The candidate is
`mlx-community/gemma-4-e2b-it-4bit`, loaded by the native Gemma 4 implementation in
`mlx-swift-lm 3.31.4`. It uses the same one-field-per-request protocol, strict raw-field scoring,
32-case multilingual fixture, and backend safety boundary as the rejected Gemma 3 baseline.

The candidate must pass all of these gates before it can enter non-authoritative shadow mode:

- at least 95% exact commands and exact raw fields;
- every required clarification correct;
- zero high-risk false executions;
- overall, command, and field p95 at most 2 seconds;
- successful cold load, cancellation, repeated-run, memory, and thermal checks on iPhone 17 Pro Max;
- a separate multilingual holdout and human-recording pipeline.

The local cached weight file is 3,581,101,896 bytes with SHA-256
`e9bea0584546fafb5ff83a1132a6c4662a8498cc6a5bcda52fc6ca562b7bafab`. Model files are ignored
by Git and must not be added to a commit or application release bundle.

Physical iPhone 17 Pro Max evidence confirms that the native runtime can open the model and
generate a strictly grounded reminder field. The smoke loaded in 2.861 seconds, generated in
3.150 seconds, used about 2,624 MB active MLX memory, and peaked at about 2,846 MB. The complete
English shard then produced:

| Metric | Result | Required |
|---|---:|---:|
| Exact commands | 7/8 (87.5%) | >=95% |
| Exact raw fields | 10/11 (90.9%) | >=95% |
| Required clarifications | 4/4 | 4/4 |
| High-risk false executions | 0 | 0 |
| Load | 2.805 s | recorded |
| Command/overall p95 | 0.770 s | <=2 s |
| Active / peak MLX memory | 2,624 / 2,849 MB | recorded |

The sole strict failure dropped `I will` from the message body `I will arrive ten minutes late`.
That is a semantic mutation, so deterministic grounding rejected it instead of hiding the error.
Because the English shard already failed both 95% gates, Mandarin and Cantonese expansion was
intentionally stopped. Gemma 4 therefore has status **rejected for Release and shadow mode** even
though it can run on the device. Release remains deterministic on every device.

The simulator compiled and exposed the official Gemma 4 registry entry, but attempting model
startup hit a simulator Metal/runtime assertion before weight loading. Simulator model results are
not qualification evidence; the physical-device result above is authoritative.

Release therefore defaults every device, including iPhone 17 Pro Max, to
`DeterministicCommandGenerator`. The signed Gemma path remains compiled for qualification but is
guarded by `signedGemmaQualifiedForRelease = false`; a valid signature, successful download, and
successful model initialization cannot override this semantic gate. The deterministic fallback
passed all 24 command examples and all 8 required clarifications across the same 32-case fixture,
with zero high-risk false executions.

These 32 cases are regression fixtures, not an unbiased holdout set. Any accepted prompt must also
pass a new multilingual holdout and the planned human-recording pipeline before release.

The current command-safety focused suite passed 29/29 tests, and the complete iOS unit target
passed 205 tests with 9 expected opt-in skips and zero failures. Coverage includes ambiguous
people/time/amount clarification, high-risk confirmation, injection, duplicate/extra keys, strict
timestamps, controlled fields, and the rules-first release fallback.

After the Gemma 4 target and package upgrade, the focused main-App regression selection
(`LocalCommandEnvelopeCanonicalizerTests`, `ModelManifestTests`, and
`VoiceCommandGoldenSetTests`) passed 40/40 tests on the iPhone 17 simulator with zero failures.

Model weight SHA-256 values used for this qualification:

- `intfloat/multilingual-e5-small`: `1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477`
- `mlx-community/gemma-3-1b-it-qat-4bit`: `b6010f6b03a83f973ca8708eb5784d5b0f80c0e7e9143dbb4c95d0eefe39c837`
- `mlx-community/gemma-4-e2b-it-4bit`: `e9bea0584546fafb5ff83a1132a6c4662a8498cc6a5bcda52fc6ca562b7bafab`

### Device validation

- iPhone 13 Pro and iPhone 17 Pro Max.
- Simulator compile smoke on arm64 only.
- Cold/warm latency, memory, thermal state, cancellation, background/foreground, and repeated-run stability.
- At least 36 human recordings: 12 per language and at least 3 speakers per language.

## Rollout

1. Compile and run the isolated package-surface smoke test.
2. Stage signed local model directories and run memory-retrieval/Gemma qualification.
3. Add MLX memory retrieval and Gemma parsing behind shadow mode; neither can change commands.
4. Fix the final-transcript-only, classifier timeout, and cancellation race gates.
5. Enable fallback for read-only `search_history` only.
6. Expand to reminder/draft, then confirmed message sending.
7. Only if the product later adopts MLX in Release, decide whether to raise the main App floor from iOS 15. Gemma 4 itself requires iOS 17 in this stack.
8. Only after release parity and rollback testing, remove the device-side LiteRT integration.

Current device policy from the measured evidence:

- iPhone 13 Pro remains rules-first with clarification. Gemma 3 1B is not eligible for the
  interactive path because one safe generation took 4.148 seconds.
- iPhone 17 Pro Max also remains rules-first in Release. Gemma may enter non-authoritative shadow
  mode only after the raw-field gate passes every locale shard and a separate holdout. It is not
  currently production-eligible.
- Multilingual E5 may proceed to a larger retrieval-only shadow benchmark on both devices. A
  retrieved memory is context only and can never authorize an action.

## Rollback

- Disable the MLX feature flag.
- Restore rules-only intent routing and the existing signed LiteRT model.
- Preserve pending CommandEnvelope checkpoints and idempotency keys.
- Never roll back the backend validation, confirmation, or audit requirements.
