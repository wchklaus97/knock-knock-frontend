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

当前主 App 的最低版本仍是 iOS 15。官方 MLX Swift 最低支持 iOS 16，所以第一阶段只新增独立的 iOS 16 qualification target；在验证通过前，不提高主 App deployment target，也不替换现有 LiteRT 路径。

## Decision

- Use Swift for the iOS application, audio pipeline, safety policy, and CommandEnvelope construction.
- Use one MLX runtime for both embedding inference and Gemma inference.
- Keep existing LiteRT integration as a rollback path until MLX reaches parity on both physical devices.
- Do not add Candle or a Rust FFI layer to the iOS application.
- Keep the Rust backend authoritative. Local models never execute actions directly.

## Pinned qualification stack

| Component | Pinned version/model | Reason |
|---|---|---|
| MLX Swift | `0.29.1` | Last compatible line used by the selected iOS 16 LM package |
| MLX Swift LM | `2.29.3` | Supports iOS 16, MLXEmbedders, and Gemma 3 1B |
| Memory embedding | `intfloat/multilingual-e5-small` | Official MLXEmbedders registry entry; multilingual semantic retrieval |
| Argument model | `mlx-community/gemma-3-1b-it-qat-4bit` | Existing Gemma 3 1B product direction with an MLX model implementation |

The latest stable MLX Swift line currently requires iOS 17 and a newer Swift toolchain. It is not used for this qualification phase.

## Isolation

`VoiceAgentBridgeMLXQualification` is a separate test scheme and links MLX only into `VoiceAgentBridgeMLXTests`.

- Normal application builds do not link MLX yet.
- An `otool` check of the generated physical-device host app showed only the existing
  `CLiteRTLM` runtime; MLX resources and code were confined to the qualification test plug-in.
- Normal unit/UI test schemes do not run MLX qualification.
- Tests require explicit `KNOCK_RUN_MLX_BENCHMARK=1`.
- Tests accept local model directories only. They do not download models from the network.
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

- Gemma returns only the argument object required by trusted local code. It does not generate
  command IDs, idempotency keys, risk, confirmation, locale, timezone, or model identity.
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
is rejected. A second bounded prompt candidate explicitly requires replacing all placeholders and
still forbids extra keys. A Simulator diagnostic compiled and linked MLX successfully but its test
host aborted during inference, so it produced no qualifying output. Physical-device reruns remain
pending because the iPhone 17 developer tunnel disconnected. The candidate was not promoted into
production source and must not be enabled before all three locale shards pass.

These 32 cases are regression fixtures, not an unbiased holdout set. Any accepted prompt must also
pass a new multilingual holdout and the planned human-recording pipeline before release.

The production deterministic safety suite passed 25/25 tests after the draft-title grounding fix.
Coverage includes ambiguous people/time/amount clarification, high-risk confirmation, injection,
duplicate/extra keys, strict timestamps, and the iPhone 13 rules-first fallback.

Model weight SHA-256 values used for this qualification:

- `intfloat/multilingual-e5-small`: `1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477`
- `mlx-community/gemma-3-1b-it-qat-4bit`: `b6010f6b03a83f973ca8708eb5784d5b0f80c0e7e9143dbb4c95d0eefe39c837`

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
7. After both physical devices pass, decide whether to raise the main App floor to iOS 16.
8. Only after release parity and rollback testing, remove the device-side LiteRT integration.

Current device policy from the measured evidence:

- iPhone 13 Pro remains rules-first with clarification. Gemma 3 1B is not eligible for the
  interactive path because one safe generation took 4.148 seconds.
- iPhone 17 Pro Max may enter non-authoritative shadow mode only after the final prompt passes all
  locale shards and a separate holdout. It is not currently production-eligible.
- Multilingual E5 may proceed to a larger retrieval-only shadow benchmark on both devices. A
  retrieved memory is context only and can never authorize an action.

## Rollback

- Disable the MLX feature flag.
- Restore rules-only intent routing and the existing signed LiteRT model.
- Preserve pending CommandEnvelope checkpoints and idempotency keys.
- Never roll back the backend validation, confirmation, or audit requirements.
