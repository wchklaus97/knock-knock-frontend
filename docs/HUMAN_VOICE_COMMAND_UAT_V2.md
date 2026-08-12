# Human Voice Command UAT v2

## 中文摘要

现有真人语料只有 12 条、每种语言 4 条、单一说话者，足以发现问题，但不足以证明生产准确率。下一轮至少收集 36 条真人命令，覆盖英语、普通话、粤语；每种语言至少 3 位说话者，并同时测试安全追问、姓名、日期时间和金额。MiniMax、ElevenLabs 或其他 TTS 只能列为合成语料，不能计入真人通过率。

## Required corpus

Collect at least 36 new recordings:

| Locale | Speakers | Commands per speaker | Minimum total |
|---|---:|---:|---:|
| `en-HK` | 3 | 4 | 12 |
| `zh-Hans-CN` | 3 | 4 | 12 |
| `yue-Hant-HK` | 3 | 4 | 12 |

Each locale must cover:

- `search_history` (read-only)
- `create_reminder` (reversible)
- `create_draft` (reversible)
- `send_message` (high risk; confirmation required)
- missing or ambiguous person/time/amount (clarification required)

At least one third of the files should include ordinary room noise or natural
speaking pace. Do not deliberately distort audio. Do not reuse one recording
under multiple labels.

## Manifest

Every WAV/M4A file must have a manifest row containing:

- opaque sample ID
- locale and speaker ID (no real name)
- expected transcript
- expected intent and canonical arguments
- expected risk level and confirmation behavior
- SHA-256 of the source file
- capture type: `human` or `synthetic`

Keep raw recordings outside Git. Import only through the opt-in UAT runner and
delete device copies after the run. Never upload user recordings to the
backend, logs, PR artifacts, or analytics.

## Pipeline validation

Run each human sample through the complete local boundary:

```text
audio -> routed STT -> locale normalization -> intent parser
      -> CommandEnvelope validation -> execute or clarification decision
```

Report STT transcript accuracy separately from command accuracy. A transcript
may differ harmlessly while producing the correct command; a correct-looking
transcript may still produce an unsafe command.

Acceptance criteria:

- per-locale STT semantic accuracy at least 90%
- overall command accuracy at least 95%
- zero high-risk false executions
- names, times, dates, and amounts must match canonical values
- ambiguous or low-confidence samples must ask for clarification
- STT p95 no more than 2 seconds on each supported device
- raw audio remains local and is removed after evidence is generated

## Frozen routing under current evidence

- Cantonese: Apple SpeechAnalyzer (`zh-HK`) first, normalize to Traditional,
  with SenseVoice only as an experimental fallback.
- Mandarin: SenseVoice candidate first when its signed runtime is available;
  preserve Simplified Chinese. Apple fallback is clarification-only until its
  same-corpus result reaches the threshold.
- English: Apple SpeechAnalyzer (`en-GB`) first, but use strict clarification
  for names, dates, times, and amounts because the current 120-sample result is
  below 90%.
- iOS versions without SpeechAnalyzer use the system speech adapter and the
  same strict clarification policy.

The route is evidence-driven and must be re-evaluated after the larger human
corpus. It does not authorize production rollout by itself.

