# Knock Knock 生产候选证据报告

更新时间：2026-08-08（Asia/Hong_Kong）

这份报告记录当前工作树和外部环境的可验证状态。它不包含账号密码、Agent key、JWT、APNs key 或任何其他 secret。

## 结论

Knock Knock 已达到“自动化验证通过、Rust Cloudflare Worker 已部署、iOS Build25 已上传”的生产候选阶段。真实 iPhone 13 Pro 的最终闭环仍未宣称完成，因为 Build25 仍在 App Store Connect 处理中，而且生产账号创建、登录、配对和手机上的两轮人工点击尚未完成。

## 已验证

### 后端与部署

- Rust Worker 是生产 source of truth；旧 Node API 仅保留为迁移诊断路径。
- Worker 地址：`https://knock-knock-backend-production.wch-klaus.workers.dev`。
- 当前部署版本：`2026.08.08-build-24`。
- `/health` 返回 `ok=true`、`api=rust`、`runtime=cloudflare-worker`、`push_mode=both`、`apns_ready=true`、`apns_production=true`；`/metrics` 返回 Rust Worker 指标。
- 远程 D1 migration 检查通过：没有待应用 migration。
- D1 备份已生成到本机受限路径，权限为 `600`，并通过非空及 `CREATE TABLE` 校验：
  `<local-backup-path>/knock-knock-d1-20260808.sql`
- 生产 D1 的只读设备元数据检查显示已有 iOS device rows，但当前 push token 长度为空；因此真实 APNs delivery 仍未被宣称完成，必须在新生产账号登录并让手机重新注册 token 后验证。
- GitHub Actions 已加入：Rust CI、十分钟健康检查/告警 issue、每日 D1 backup workflow。
- 最新 backend commit 的 Rust CI 已成功；生产健康 workflow 手动运行也成功，并执行了恢复告警分支。
- GitHub repository variables 已配置；每日备份仍需要人工添加专用、最小权限的 `CLOUDFLARE_API_TOKEN` Actions secret。本机 Wrangler OAuth 登录存在，但不转存个人广权限 OAuth 到 GitHub。
- APNs readiness 现在会解析并验证 `.p8` 私钥格式，不再只判断 secret 是否非空。

### Rust 与协议

- Rust unit tests：9 passed / 0 failed。
- `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo check --target wasm32-unknown-unknown` 通过。
- `pnpm test:e2e` 通过：auth、pairing、skill、session、chat、多轮、phone、confirm、claim、result、push、refresh。
- `pnpm test:rc` 通过：refresh rotation、Agent-key rotation、history、metrics。
- `pnpm test:paperclip` 通过：5 个工具、同一 `session_id` 恢复、phone reply 绑定、result retry-safe。
- `pnpm test:canonical:codex:multiturn` 通过：同一 `session_id` 和 `chat_id` 完成两次 action 流程，backend 为 Rust。
- `pnpm test:installer` 通过：Codex、Cursor、Paperclip skill/MCP snippets 可安装且不会覆盖共享 host config；`pnpm typecheck` 通过。

### iOS 与发布

- `pnpm test:ios` 通过：9 个 model tests + 3 个 UI tests，覆盖搜索/过滤、needs_user、destructive 二次确认、pairing code 生成/复制，以及 Release fixture 清理。
- Build21/Build25 archive 已使用官方 Apple Distribution 签名导出；Build25 bundle ID 为 `hk.knockknock.app`，`aps-environment=production`，`get-task-allow=false`。
- Build25 已于 2026-08-08 16:21 通过 `xcodebuild -exportArchive` 成功上传 App Store Connect；Apple 已接受上传并显示为 processing，尚未完成 TestFlight 可安装状态确认。
- Build25 加入了 Release 首次打开默认“创建账号”的 onboarding，并明确说明 Knock Knock 密码独立于 Apple、TestFlight 和 Codex；最新 IPA SHA-256 为 `7c8fe2d8b73e521d30052ba8426a58de5ffe8b12a090141c62b125205fc9fba1`，上传前 `strings` fixture 扫描为 clean。
- 设备级只读检查确认目标为 iPhone 13 Pro，当前安装仍是 `0.1.0 (Build20)`；最近检查设备已连接且处于解锁状态，但账号密码仍必须由用户自行输入。
- Release archive script 现在要求显式传入未使用的 `IOS_BUILD_NUMBER`，默认使用 manual Apple Distribution profile，避免重复 build 或再次误用 Automatic signing。
- 最新干净 Release Build25 IPA 已重新归档并扫描确认不包含本地 demo credentials；本地 fixture 只在 Debug/Simulator 路径使用。

## 尚未完成的硬门槛

1. 等待 Build25 完成 App Store Connect processing，确认在 TestFlight 可安装，并在 iPhone 13 Pro 安装/更新。
2. 在 App 内选择 **Create an account**，由用户自己设置至少 8 位密码；密码不会交给 Codex。
3. 在手机上生成 pairing code，并由 canonical Codex host claim。
4. 用生产 Worker 完成同一 `session_id/chat_id` 的两次：`needs_user → 手机回答 → Agent 恢复`。
5. 观察真实 APNs 通知；必要时同时确认 `PUSH_MODE=both` 的 fallback 行为。
6. 在 GitHub Actions 中添加 Cloudflare API token/account ID 后手动运行一次 backup workflow。

## 用户下一步

Build25 在 TestFlight 显示可用后：

```text
TestFlight → 更新 Knock Knock 到 Build25
Knock Knock → Create an account → 自己输入邮箱和新密码 → Create account
```

完成后只需告诉 Codex“已登录”，不要发送密码。Codex 再继续完成 pairing 和真实两轮手机测试。

## 发布判断

当前判断是：**Release Candidate（自动化与部署通过，真实手机最终验收待人工完成）**，不是“已经完全生产上线”。
