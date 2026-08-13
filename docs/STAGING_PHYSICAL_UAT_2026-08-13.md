# Staging Physical-Device UAT — 2026-08-13

## 中文摘要

本轮在 iPhone 13 Pro 与 iPhone 17 Pro Max 上验证了最新 Staging 客户端。两部设备的核心 UI 测试全部通过；同账号的 Session、Push 和 Cursor 最终一致；确定性断网测试证明本地缓存不会丢失，恢复网络后会补齐遗漏数据。APNs token 重用修复合并后，两部锁屏真机都由用户确认收到真实 Staging 通知。2026-08-13 18:03 HKT 也完成了 iPhone 13 Pro 的真实飞行模式、Wi-Fi 关闭、USB 保持连接测试：App 正常启动、请求真实超时且没有命中 URLCache、本地 SQLite 数据完整保留。18:43 HKT 恢复 Wi-Fi/VPN 后，手机 cursor 从 2042 前进到 2049，唯一 reconnect Session 自动写入一次，缓存由 22 个 Session 增加至 23 个且 pending operation 为 0。随后完成同账号双设备动作 UAT：iPhone 17 Pro Max 确认高风险操作并进入 `queued`，iPhone 13 Pro 自动同步同一 Session，最终两台手机都通过以 backend `session_id` 定位的 UI 收敛测试。36 条以上真人语音及稳定性测试仍需完成。

## Build under test

- iOS source: `c3edcac` plus the cache-policy, initial-sync and physical-UAT changes in this branch
- Configuration: `Staging`
- Bundle ID: `hk.knockknock.app`
- App version: `0.1.0 (25)`
- Backend: `https://knock-knock-backend-staging.wch-klaus.workers.dev`
- Devices:
  - iPhone 13 Pro
  - iPhone 17 Pro Max

## Clean Simulator regression

The final isolated Worker/D1 Simulator regression completed at 2026-08-13
18:11 HKT with 210 tests: 198 passed, 12 environment-gated tests skipped, and
zero failed. The UI portion contained six tests: three core UI flows passed and
the three explicit physical-device opt-in tests were skipped as designed.

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

This proves cache retention and REST reconciliation. The true-airplane run
below additionally proves the physical network and persistence boundary; a
human-observed offline status-pill transition remains a separate release gate.

### True airplane-mode USB evidence — iPhone 13 Pro

At 2026-08-13 18:03 HKT, the physical iPhone 13 Pro was kept unlocked and
connected to the Mac by USB with airplane mode enabled and Wi-Fi disabled. The
already-installed Staging app launched successfully without reinstalling or
starting an XCTest runner.

The copied app-owned SQLite database proved that the offline launch retained:

- 22 cached Sessions and 50 cached Push records;
- the unique `Airplane recovery 20260813-173804` Session;
- both the phone `cursor` and `applied_cursor`;
- zero pending operations.

The launch generated two real network failures after about 15.7 seconds. Both
had `response_status=-1`, zero request bytes, zero response bytes, and
`cache_hit=false`; CFNetwork finished them with `NSURLErrorDomain -1001`.
Although iOS still exposed the VPN virtual interface `utun4`, all candidate
connections stalled and remained unconnected. Therefore it was not a usable
Internet path during this run.

This is physical evidence for offline launch, explicit SQLite retention, and
failure without URLCache substitution. It is not yet visual evidence for the
offline status pill: iOS refused to start the development XCTest runner while
fully offline, and iPhone Mirroring requires wireless connectivity. The final
visual transition must start its trusted runner while online, switch the phone
offline during the active test, then restore the network and verify convergence.

### Network-restoration reconciliation

At 2026-08-13 18:43 HKT, Wi-Fi and the required VPN route were restored while
the iPhone 13 Pro remained unlocked and USB-connected. A unique Staging Session,
`Reconnect UAT 20260813-183857`, advanced the server cursor beyond the phone's
offline cursor. A clean foreground relaunch then reconciled without a manual
refresh:

- `cursor` and `applied_cursor` advanced together from 2042 to 2049;
- the unique reconnect Session appeared exactly once;
- the cached Session count advanced from 22 to 23;
- the pending operation count remained zero.

This closes the physical offline-retention and post-network-restoration data
convergence gate. Only the separately observable status-pill transition remains.

## Two-device convergence

The same account was active on both physical devices. After creating the unique
`Dual device UAT 20260813-184459` Session, both devices advanced to cursor and
`applied_cursor` 2053, stored that Session exactly once, and had zero pending
operations. Both physical screens then passed an opt-in convergence UI test
against that same backend-owned Session.

The action-side test subsequently created
`ses_fe5ec2e2ffd334e6ab6f324a106f85b9`. On the iPhone 17 Pro Max, the app opened
the authoritative decision detail, required destructive confirmation, and
reached the authoritative `queued` state. A foreground relaunch on the iPhone
13 Pro reconciled to server cursor 2062 and stored that same queued Session
exactly once with zero pending operations. Finally, both phones ran the same
exact-session UI assertion in parallel and each passed 1/1.

The first observer assertion had searched for an exact title only in the
initial `LazyVStack` viewport. Because the product correctly prioritizes
needs-user decisions above queued work and titles are not unique, that selector
could report a false failure even though SQLite and counters had already
converged. The physical UAT now filters by the opaque backend `session_id`
before asserting the title; the corrected test passed on both phones.

Together these runs prove:

- one device can confirm an action while the other observes the resulting
  authoritative state;
- the same exact Session converges to both SQLite stores and both UIs;
- cursor reconciliation does not create a duplicate Session or pending command;
- list ordering and lazy rendering no longer make the UAT inspect a namesake or
  only the initial viewport.

## APNs status

Earlier Staging delivery evidence recorded two attempted and two accepted APNs
requests. A later repeated notification recorded one accepted request and one
`429 TooManyProviderTokenUpdates` response. Backend PR #33 changed the provider
to reuse one JWT for a device batch and for 50 minutes within a Worker isolate.
After the fix was merged and deployed, the user confirmed a real lock-screen
Staging notification on both the iPhone 13 Pro and iPhone 17 Pro Max. This gate
is passed for sandbox Staging; production APNs remains human-controlled release
work.

## Remaining gates

- perform the online-started, human-observed airplane-mode status-pill transition;
- run live push-to-talk/VAD and the 36+ human-voice corpus;
- complete thermal, interruption, cancellation, and repeated-command testing;
- retain release evidence and obtain human production approval.
