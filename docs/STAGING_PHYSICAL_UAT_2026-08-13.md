# Staging Physical-Device UAT — 2026-08-13

## 中文摘要

本轮在 iPhone 13 Pro 与 iPhone 17 Pro Max 上验证了最新 Staging 客户端。两部设备的核心 UI 测试全部通过；同账号的 Session、Push 和 Cursor 最终一致；确定性断网测试证明本地缓存不会丢失，恢复网络后会补齐遗漏数据。真实 APNs 曾成功送达两台设备，但高频回归时出现一次 `TooManyProviderTokenUpdates`，因此 APNs 仍需 backend PR #33 合并并重新验证。真实飞行模式 UI、36 条以上真人语音及稳定性测试仍未完成。

## Build under test

- iOS source: `eacace4887019dabaa2f71863930d5fbe122cad6` plus the pagination/reconciliation changes in this PR
- Configuration: `Staging`
- Bundle ID: `hk.knockknock.app`
- App version: `0.1.0 (25)`
- Backend: `https://knock-knock-backend-staging.wch-klaus.workers.dev`
- Devices:
  - iPhone 13 Pro
  - iPhone 17 Pro Max

## Automated physical UI results

| Device | Gate | Result |
|---|---|---|
| iPhone 13 Pro | Home and drawer | Passed |
| iPhone 13 Pro | Settings and pairing | Passed |
| iPhone 13 Pro | Destructive action confirmation and queued state | Passed |
| iPhone 17 Pro Max | Home and drawer | Passed |
| iPhone 17 Pro Max | Settings and pairing | Passed |
| iPhone 17 Pro Max | Destructive action confirmation and queued state | Passed |

The iPhone 13 Pro confirmation flow showed the authoritative decision detail,
the confirmation UI, and the queued result. The app no longer waits for a full
history refresh before showing the authoritative reply or confirmation state.

## Offline recovery

A deterministic unreachable endpoint was injected only for one launch. The
test proved all of the following:

- the existing 20-session SQLite cache remained available while offline;
- a Session created on the backend during the outage was absent while offline;
- the persisted Staging URL was not replaced by the test-only endpoint;
- after a normal relaunch, the new Session appeared and both stored cursors
  advanced to the same new value.

This proves cache retention and REST reconciliation. A human-observed airplane
mode UI run remains a separate release gate.

## Two-device convergence

The same account was active on both physical devices. After creating one unique
Session and Push, each device's copied SQLite database contained:

- the same new Session and state;
- the same Push identifier;
- the same `cursor` and `applied_cursor` value;
- one 20-row initial summary page.

This proves eventual convergence at the persisted-data boundary. Simultaneous
human interaction on both screens remains a final UAT step.

## APNs status

Earlier Staging delivery evidence recorded two attempted and two accepted APNs
requests. A later repeated notification recorded one accepted request and one
`429 TooManyProviderTokenUpdates` response. Backend PR #33 changes the provider
to reuse one JWT for a device batch and for 50 minutes within a Worker isolate.
After that PR is deployed to Staging, the release gate requires repeated runs
with two attempts, two accepts, and no provider-token update error.

## Remaining gates

- merge and deploy backend PR #33, then repeat real APNs delivery;
- perform the human-observed airplane-mode UI recovery run;
- perform simultaneous two-device interaction and visual convergence;
- run live push-to-talk/VAD and the 36+ human-voice corpus;
- complete thermal, interruption, cancellation, and repeated-command testing;
- retain release evidence and obtain human production approval.
