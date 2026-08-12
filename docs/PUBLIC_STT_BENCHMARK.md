# Public Trilingual STT Benchmark

Updated: 2026-08-13 (Asia/Hong_Kong)

## Purpose

This benchmark separates model quality from the pronunciation and recording
conditions of the original 12-command, single-speaker UAT set. It measures STT
only. Public sentences are not command fixtures and must not be counted toward
CommandEnvelope or action-safety accuracy.

The qualification set contains 120 clips:

| Locale | Clips | Minimum speakers | Source |
|---|---:|---:|---|
| `en-HK` | 40 | 8 | Common Voice 17, `Hong Kong English`, train split |
| `zh-Hans-CN` | 40 | 8 | AISHELL-1 |
| `yue-Hant-HK` | 40 | 8 | Common Voice 22 Cantonese |

English uses the train split because the pinned mirror's test split has only 12
rows that pass the vote gate. This is a frozen model-qualification corpus, not
a training/test generalization claim; no candidate model is trained or tuned on
these clips.

Every clip must be 2–12 seconds, mono PCM signed 16-bit at 16 kHz, louder than
-38 dBFS RMS, and below a 1% clipping ratio. Common Voice rows require at least
two up-votes and zero down-votes. No speaker may contribute more than five clips
per locale.

## Reproducible preparation

Run from the repository root:

```bash
python3 scripts/prepare-public-stt-benchmark.py \
  --output /private/tmp/knock-knock-public-stt-v1
```

The command downloads only selected clips and small AISHELL per-speaker
archives. It does not download full Common Voice or AISHELL bundles. The output
contains:

- `KNOCK_KNOCK_VOICE_GOLDEN_V2.json`: STT-only references accepted by the
  isolated SenseVoice test target;
- `audio-manifest.jsonl`: source revision, source row/utterance, anonymized
  speaker identifier, audio metrics, and source/normalized SHA-256;
- `SOURCES_AND_LICENSES.json`: pinned source plan and license notes;
- `audio/`: local test WAV files, never committed or uploaded.

Use `--plan-only` to verify source revisions and license metadata without
downloading audio. Use a lower `--count-per-locale` only for tooling smoke tests;
it is not a model qualification result.

## Sources and license boundary

- Mozilla Common Voice is available under CC0-1.0. The preparation tool uses
  pinned Hugging Face mirrors for selective local access because downloading
  the official full language archives would exceed the development machine's
  storage budget. Do not redistribute the generated subset; obtain public
  releases through Mozilla Data Collective.
- AISHELL-1 is published as OpenSLR SLR33 under Apache-2.0. The pinned
  `AISHELL/AISHELL-1` repository mirrors that corpus as small per-speaker
  archives.
- Dataset permissions do not imply model redistribution permission. Model and
  runtime licenses remain separate release gates.

Primary references:

- <https://commonvoice.mozilla.org/terms>
- <https://commonvoice.mozilla.org/en/datasets>
- <https://www.openslr.org/33/>

## Evaluation rules

- English uses word error rate; Mandarin and Cantonese use character error
  rate. Report accuracy as `max(0, 1 - error_rate)`.
- Report each locale separately plus p50/p95 inference time, load time, and
  resident-memory increase for each physical device.
- Keep automatic-language and forced-language runs separate.
- Compare these results with the original 12-command UAT in a separate table.
  Never average the two datasets together.
- Public benchmark success cannot approve command execution. The command set
  must independently retain 0 high-risk false executions and at least 95%
  correct CommandEnvelopes.

## SenseVoice INT8 physical-device result

The pinned 120-clip set was run in automatic-language mode with two CPU threads
using `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09`. Both devices
produced identical transcripts; newer hardware improved latency and load time,
not recognition accuracy.

| Device | `en-HK` WER accuracy | `zh-Hans-CN` CER accuracy | `yue-Hant-HK` raw CER accuracy | Overall p95 | Load | Memory increase |
|---|---:|---:|---:|---:|---:|---:|
| iPhone 13 Pro | 71.8% / 198 ms | 97.9% / 145 ms | 65.3% / 203 ms | 198 ms | 667 ms | about 323.6 MiB |
| iPhone 17 Pro Max | 71.8% / 168 ms | 97.9% / 112 ms | 65.3% / 159 ms | 159 ms | 424 ms | about 322.5 MiB |

SenseVoice commonly emitted simplified characters for traditional Cantonese
references. A separate OpenCC `t2s` normalization of both reference and
hypothesis reduced Cantonese edits from 144 to 39 out of 415 characters, or
**90.6% script-normalized accuracy**. Raw 65.3% remains the correct UI-output
fidelity score because the app requires traditional Cantonese text.

Forcing `en` on the iPhone 13 Pro did not fix English: accuracy was 71.3% with
201 ms p95, slightly below automatic mode. Therefore language detection was not
the primary English failure.

Decision: do not use SenseVoice as the unified trilingual STT model. It qualifies
as a Mandarin candidate and narrowly qualifies for Cantonese recognition only
when followed by a tested Traditional-Chinese conversion layer. It does not
qualify for Hong Kong English. The original 12-command human UAT also remains a
separate product-safety failure and is not overridden by this public benchmark.

## Privacy and cleanup

The script hashes Common Voice client identifiers before writing the manifest.
Raw source files exist only in a guarded temporary directory. Generated WAV
files stay outside git and are staged only into the isolated test container.
After physical-device UAT, run the existing guarded SenseVoice cleanup test and
delete the local output directory after preserving only aggregate results and
the non-audio manifest.
