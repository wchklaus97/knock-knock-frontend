# Status Enum Cheat Sheet / 状态枚举速查

Aligned with the backend canonical OpenAPI contract and the current Rust Worker.

## Canonical backend architecture references

The backend contract is the sole protocol source of truth. This iOS status document is a pointer only and must not copy the full architectural decisions; use the backend references below for canonical updates.

- [Backend architecture decisions](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/ARCHITECTURE_DECISIONS.md) — canonical architecture decisions (cross-repo placeholder).
- [Backend implementation roadmap](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/IMPLEMENTATION_ROADMAP.md) — canonical implementation sequencing (cross-repo placeholder).
- [Backend OpenAPI contract](https://github.com/wchklaus97/knock-knock-backend/blob/main/contracts/openapi.yaml) — canonical REST, SSE, error, and `CommandEnvelope v1` contract.
- [Voice model release runbook](https://github.com/wchklaus97/knock-knock-backend/blob/main/docs/VOICE_MODEL_RELEASE_RUNBOOK.md) — canonical artifact signing, staging, evaluation, and rollback procedure.

The current voice completion branch adds strict command canonicalization,
backend-owned presentation, signed private-model delivery, and crash-safe
SQLite command reconciliation. Foreground-only capture preflight,
clarification routing, persistent failed offline operations, and silent APNs
wake-to-REST reconciliation are also implemented. Exact test evidence is maintained in the
backend release report. Model publication/public-key configuration,
real-model accuracy, physical-device voice/APNs/two-device evaluation, and
human release approval remain backend-canonical release gates.

## ProgressStatus — `update_progress` only / 仅进度

| Value | EN | 中文 |
|-------|----|------|
| `started` | Work started | 已开始 |
| `running` | In progress | 进行中 |
| `blocked` | Blocked (non-user) | 阻塞（非用户） |
| `succeeded` | Progress milestone | 阶段成功 |
| `failed` | Progress failure | 进度失败 |
| `cancelled` | Cancelled | 已取消 |

**Push rule / 推送规则:** `update_progress` **NEVER** pushes. / **永不**推送。  
App list may show progress; Dev Push inbox must stay empty.

**Percentage rule / 百分比规则:** `percent` is optional. Agents must omit it
when they cannot make a truthful estimate; the app renders an indeterminate
working state. `0` means genuinely started, and `100` is reserved for completed
work. The backend preserves a previously reported percentage when a later
progress update omits `percent`.

---

## EventStatus — `report_event` (may push) / 可能推送

| Value | EN | 中文 | Push? |
|-------|----|------|-------|
| `needs_user` | Agent decided user needed | 代理判定需用户 | **Always / 始终** |
| `succeeded` | Terminal success | 终态成功 | Only if `actions` or `force_push` |
| `failed` | Terminal failure | 终态失败 | Only if `actions` or `force_push` |

Center does **not** infer `needs_user`. / 中心**不**猜测 `needs_user`。  
`needs_user` requires non-empty `actions` (skill action ids).

---

## SessionState — 会话状态

`open` → `running` → `needs_user` → `awaiting_confirm` → `queued` → `claimed` → `closed` / `expired`

| Value | EN | 中文 |
|-------|----|------|
| `open` | Just created | 刚创建 |
| `running` | Agent working | 代理工作中 |
| `needs_user` | Waiting for phone reply | 等待手机回复 |
| `awaiting_confirm` | Destructive 2nd confirm | 破坏性二次确认 |
| `queued` | Action queued for agent (including a phone cancellation) | 动作已入队（包括手机取消） |
| `claimed` | Agent claimed action | 代理已认领 |
| `closed` | Finished | 已结束 |
| `expired` | TTL exceeded | 已过期 |

**TTL:** session default ≤ 24h; destructive confirm ≤ 30m.  
**TTL：** 会话默认 ≤ 24 小时；破坏性确认 ≤ 30 分钟。

---

## ActionRisk — 动作风险

| Value | EN | 中文 | Confirm? |
|-------|----|------|----------|
| `low` | Safe / ack | 低风险 | No — queue immediately / 否，立即入队 |
| `medium` | Mutating | 写入/变更 | Per skill `confirm` |
| `high` | High impact | 高影响 | Per skill `confirm` |
| `destructive` | Irreversible | 破坏性 | **Required** 2nd confirm / **必须**二次确认 |

Phone: `low` → `queued`; `destructive` (or `confirm:true`) → `pending_confirm` / session `awaiting_confirm`. A second `confirm:false` queues an agent-visible action with `cancelled_by_user: true`, so a cancellation is never silently lost.
