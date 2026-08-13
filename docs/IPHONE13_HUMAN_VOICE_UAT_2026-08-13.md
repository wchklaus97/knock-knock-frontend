# iPhone 13 Pro Human Voice UAT — 2026-08-13

## 中文摘要

本轮只使用 iPhone 13 Pro，测试 12 条单一说话者真人录音：英语、普通话、
粤语各 4 条。`SpeechAnalyzer` 和系统 Speech 都能返回 12/12 条最终文字，
但严格文字准确率分别只有 63.64% 和 62.57%，没有达到每种语言至少 90%
的发布门槛。

完整本地安全流水线正确拒绝了不可靠输出：3/3 条追问样本正确追问，
高风险错误执行为 0；但 9 条命令没有一条达到严格参数完全一致。因此本轮
结论是“安全失败”，不是语音功能通过。原始录音没有上传、没有加入 Git，
测试后已经从手机测试目录移除。

## Scope and evidence boundary

| Item | Value |
|---|---|
| Device | iPhone 13 Pro (`iPhone14,2`), iOS 26.6.1 |
| App baseline | frontend `1304731205ef400ea82391d84d3528b780deab05` |
| Corpus | 12 human recordings, one speaker, four per locale |
| Locales | `en-HK`, `zh-Hans-HK`, `yue-Hant-HK` |
| STT adapters | SpeechAnalyzer qualification adapter and system Speech adapter |
| Intent runtime | `deterministic-rules-1.0.0` |
| Network | Not required for STT or intent parsing |
| Backend execution | Not enabled for this corpus run |

The run used the same 12 recordings for both adapters. Every recording produced a
final transcript. The strict transcript score is:

```text
accuracy = (reference units - edit distance) / reference units
```

The expected command labels were aligned to the recording order from the handoff;
they were not independently verified as word-for-word human transcripts. The strict
scores are therefore provisional discovery evidence, not a production-quality claim.
Observed entity substitutions, including contact and project names, are nevertheless
real release blockers.

## STT comparison

| Adapter | Locale | Final results | Strict accuracy | p50 | p95 |
|---|---|---:|---:|---:|---:|
| SpeechAnalyzer | `en-HK` | 4/4 | 48.84% | 184 ms | 313 ms |
| SpeechAnalyzer | `zh-Hans-HK` | 4/4 | 69.57% | 158 ms | 202 ms |
| SpeechAnalyzer | `yue-Hant-HK` | 4/4 | 66.67% | 141 ms | 164 ms |
| SpeechAnalyzer | Overall | 12/12 | 63.64% | — | 313 ms per-locale maximum |
| System Speech | `en-HK` | 4/4 | 48.84% | 618 ms | 1,017 ms |
| System Speech | `zh-Hans-HK` | 4/4 | 62.32% | 482 ms | 650 ms |
| System Speech | `yue-Hant-HK` | 4/4 | 70.67% | 362 ms | 438 ms |
| System Speech | Overall | 12/12 | 62.57% | — | 1,017 ms per-locale maximum |

SpeechAnalyzer remains the preferred iPhone 13 qualification route because it is
faster and slightly more accurate overall. Neither adapter is approved for
unrestricted commands under this evidence.

## End-to-end local safety result

| Adapter | Exact commands | Correct clarifications | High-risk false executions | STT p95 | Intent p95 | Total p95 |
|---|---:|---:|---:|---:|---:|---:|
| SpeechAnalyzer | 0/9 | 3/3 | 0 | 486 ms | 3 ms | 487 ms |
| System Speech | 0/9 | 3/3 | 0 | 781 ms | 3 ms | 782 ms |

Some reversible draft failures differed only in spoken-number formatting, such as
Chinese numerals versus Arabic digits. They remain failures under the frozen exact
gate. Even if those cases were treated as semantically equivalent, this corpus would
remain far below the 95% command threshold. Contact and project entity errors must
not be normalized or guessed.

## Safety and privacy evidence

- Ambiguous samples asked for clarification instead of creating a command.
- No high-risk false execution occurred with either STT adapter.
- STT output did not call an API or execute an action directly.
- The deterministic parser continued to rebuild risk and confirmation fields.
- Raw recordings stayed local and were not added to source control, CI artifacts,
  analytics, or backend requests.
- The exact staged device audio directory was removed after reports were copied;
  a known staged WAV was no longer retrievable from the device.
- Machine-readable JSON and `.xcresult` evidence remains local to the test Mac and
  contains no raw audio.

## Decision

This 12-recording pilot **fails the voice release gate safely**.

- Keep SpeechAnalyzer as the preferred iPhone 13 experimental adapter.
- Keep strict clarification for names, dates, times, amounts, and uncertain text.
- Do not run the 144-profile expansion because the 12-recording core gate failed.
- Do not enable unrestricted voice commands or claim production readiness.
- Do not lower the frozen accuracy or safety thresholds.

## Remaining qualification

1. Collect at least 36 independently labeled human recordings with at least three
   speakers per locale, following `HUMAN_VOICE_COMMAND_UAT_V2.md`.
2. Verify every expected transcript and canonical command before scoring.
3. Re-run the same-corpus SpeechAnalyzer, system Speech, Whisper, and SenseVoice
   comparison when their signed local runtimes are available.
4. Run live push-to-talk, VAD stop/finalization, interruption, memory, and thermal
   tests on iPhone 13 Pro.
5. Only after the core human gate passes, test authenticated command submission,
   idempotency, confirmation, offline recovery, and device convergence.

Physical lock-screen APNs observation, true airplane-mode recovery, and simultaneous
two-phone UI convergence were outside this iPhone-13-only run and remain open UAT
items.
