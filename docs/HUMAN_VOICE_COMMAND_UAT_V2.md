# Human Voice Command UAT v2

## 中文摘要

现有真人语料只有 12 条、每种语言 4 条、单一说话者，足以发现问题，但不足以证明生产准确率。下一轮至少收集 36 条真人命令，覆盖英语、普通话、粤语；每种语言至少 3 位说话者，并同时测试安全追问、姓名、日期时间和金额。MiniMax、ElevenLabs 或其他 TTS 只能列为合成语料，不能计入真人通过率。

2026-08-13 的 iPhone 13 Pro 单一说话者试跑结果见
[iPhone 13 Pro Human Voice UAT](IPHONE13_HUMAN_VOICE_UAT_2026-08-13.md)：
准确率未通过，但 3/3 条追问正确且高风险错误执行为 0。它不能替代下面要求的
至少 36 条、多说话者正式语料。

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

The machine-enforced minimums are:

- at least 36 manifest rows in total and at least 12 for each required locale
- at least three distinct opaque speaker IDs in each locale
- at least four recordings for every included speaker ID
- all four command intents in every locale
- at least one `person`, one `time`, and one `amount` clarification row in
  each locale
- one unique sample ID, relative path, and audio content hash per row
- `capture_type: "human"` for every row
- every manifest path resolves to decodable WAV/M4A audio, and every lowercase
  WAV/M4A file in the corpus appears exactly once in the manifest
- reminder timestamps are semantically valid RFC 3339 values

The validator cannot determine whether a decodable file contains a real human,
TTS, or replayed audio. `capture_type: "human"` is a collector declaration, not
technical proof. A human reviewer must check provenance, participant consent,
speaker identity separation, and privacy before passing the gate.

At least one third of the files should include ordinary room noise or natural
speaking pace. Do not deliberately distort audio. Do not reuse one recording
under multiple labels. The room-noise/natural-pace proportion remains a manual
review item; all other minimums above are enforced by the validator.

## External corpus layout and validation

Keep the corpus in an absolute, non-symlink directory outside this Git
worktree. Do not place raw recordings under a checkout, even temporarily. The
validator rejects a corpus inside this worktree, symlinked directories or audio
paths, unsafe relative paths, and files whose bytes do not match their declared
SHA-256.

```text
/absolute/private/corpus/
├── manifest.jsonl
└── audio/
    ├── en-HK/
    ├── zh-Hans-CN/
    └── yue-Hant-HK/
```

From the repository root, run:

```bash
scripts/validate-human-voice-corpus.sh --help
scripts/validate-human-voice-corpus.sh --self-test
scripts/validate-human-voice-corpus.sh \
  --corpus-dir /absolute/private/corpus \
  --provenance-consent-reviewed
```

The command prints one summary line on success and a concise reason on failure.
It creates a private immutable snapshot of `manifest.jsonl`, inventories and
decodes the referenced audio locally, and verifies content hashes; it never
uploads, moves, or copies audio. Validation requires `bash`, `jq`, `python3`,
and either `ffprobe` or macOS `afinfo`. `--provenance-consent-reviewed` must be
supplied only after the manual review below is complete.

## Manual provenance, consent, and privacy gate

Before using `--provenance-consent-reviewed`, a human reviewer must confirm:

- each file is a direct recording of a consenting person, not TTS, replayed,
  voice-cloned, or converted synthetic audio
- each opaque speaker ID maps to one distinct participant, with at least four
  recordings for that participant
- transcripts, recipients, message bodies, project names, dates, and amounts
  are fictional test data and contain no real personal or business information
- the manifest and generated textual evidence remain local and are never
  attached to a public PR, analytics, or backend request
- raw recordings and identifying consent records follow the agreed local
  retention period and are securely removed after UAT sign-off

The PR may record only aggregate counts, accuracy, latency, device/runtime
versions, and pass/fail results. It must not include raw audio, verbatim private
utterances, participant identities, or the private manifest.

## Manifest contract

`manifest.jsonl` contains exactly one JSON object on every physical line; blank
lines are rejected. The
[JSON Schema](HUMAN_VOICE_CORPUS_MANIFEST.schema.json) describes one row; the
script additionally enforces corpus-wide counts, uniqueness, coverage, path
containment, non-symlink files, and actual SHA-256 values.

Every WAV/M4A file must have one manifest row containing:

- opaque sample ID
- locale and opaque speaker ID
- safe audio path relative to the corpus root and SHA-256 of the source bytes
- expected transcript
- expected outcome, canonical intent/arguments, risk, and confirmation behavior
- ambiguity kind: `person`, `time`, `amount`, or `none`
- capture type: `human`

Speaker IDs must match `spk_[0-9a-f]{12,64}`. Generate a random token for each
consenting participant and reuse it only for that participant's rows. Never put
the participant's real name, initials, email address, handle, or phone number in
`speaker_id`, `sample_id`, or `relative_path`. Audio paths may contain only safe
slash-separated components, must name a non-empty regular file, and must end in
lowercase `.wav` or `.m4a`.

Command rows use `expected_outcome: "command"`,
`ambiguity_kind: "none"`, and these canonical semantics:

| `expected_intent` | Exact `expected_args` shape | `risk_level` | `needs_confirmation` |
|---|---|---|---:|
| `search_history` | `{"q":"…"}` | `low` | `false` |
| `create_reminder` | `{"title":"…","due_at":"RFC 3339 timestamp"}` | `low` | `false` |
| `create_draft` | `{"body":"…"}` with optional `title` | `low` | `false` |
| `send_message` | `{"recipient":"…","body":"…"}` | `high` | `true` |

Clarification rows are deliberately non-executable. They use
`expected_outcome: "clarification"`, `expected_intent: null`,
`expected_args: {}`, `risk_level: null`, `needs_confirmation: false`, and a
`person`, `time`, or `amount` ambiguity. A high-risk confirmation is not a
clarification: a complete `send_message` remains a command whose execution
requires confirmation.

Example JSONL (each object is one physical line):

```jsonl
{"schema_version":1,"sample_id":"hvc_7a41f0c2e901","locale":"en-HK","speaker_id":"spk_0f4a21b9c8d7","capture_type":"human","relative_path":"audio/en-HK/hvc_7a41f0c2e901.wav","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","expected_transcript":"Send Alex a message saying I am on my way","expected_outcome":"command","expected_intent":"send_message","expected_args":{"recipient":"Alex","body":"I am on my way"},"risk_level":"high","needs_confirmation":true,"ambiguity_kind":"none"}
{"schema_version":1,"sample_id":"hvc_8b52a1d3f012","locale":"en-HK","speaker_id":"spk_91e3b5c7d9f1","capture_type":"human","relative_path":"audio/en-HK/hvc_8b52a1d3f012.m4a","sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","expected_transcript":"Send them two hundred dollars","expected_outcome":"clarification","expected_intent":null,"expected_args":{},"risk_level":null,"needs_confirmation":false,"ambiguity_kind":"amount"}
```

Keep raw recordings outside Git. Import only through the opt-in UAT runner and
delete device copies after the run. Never upload user recordings to the
backend, logs, PR artifacts, or analytics. Treat the manifest as sensitive too:
keep it outside Git, fictionalize all expected text and arguments, and delete or
retain it under the same approved local policy as the recordings.

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
