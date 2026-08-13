# Checkpoint 6 · Outcome / Notification / Retention

验证日期：2026-08-13

## 结论

Checkpoint 6 的结果事实链通过。Runtime 最终文本只能形成 `reported`；签名 Tool Result 形成 `tool-confirmed`；只有独立 HMAC 验证入口可以形成 `externally-verified`。三种等级均进入 Task 时间线，Agent 文本不能自行升级证据等级。

备用通知使用 Notification SDK 的真实 loopback HTTP adapter。受控 receiver 验证 HMAC、时间窗与 `Idempotency-Key`，返回 delivery receipt；同一结果只送达一次。第二个结果先收到 Runtime 原生 `DELIVERED` 回执，待发 fallback 被标记为 `NATIVE_DELIVERED` 并抑制，重复外部副作用为 0。

## 可复现命令

```bash
pnpm test:e2e:outcome
```

结果：`PASS`。运行环境为 WakeOnCue Node `v26.7.0`，不需要 Docker，也不需要 OpenClaw Node 24。受控运行的忽略目录 artifact 为 `.runtime/outcome-notification-e2e/2026-08-13T02-51-45-950Z/result.json`；脱敏稳定摘要见 `docs/evidence/artifacts/outcome-notification-e2e-2026-08-13.json`。

## 验证点

- fallback HTTP 请求签名有效，receiver 实际收到 1 次；Delivery Ledger 为 `DELIVERED`。
- `task/outcome/channel` 是通知去重键；再次 claim 不产生发送。
- 原生渠道成功后，相同结果的 fallback outbox 结束为 `NATIVE_DELIVERED`，receiver 总计仍为 1。
- 审批和高风险失败/`UNKNOWN` 立即升级；普通摘要与 verified success 遵守 quiet hours、每日预算和原生回执等待窗口。
- 固定模板 payload 只携带 Task、状态、验证等级和 deep link，不复制 Agent 自由文本。
- Feedback API 要求 `Idempotency-Key`，相同请求可重放，不同 payload 复用同一 key 返回冲突。
- 删除入口需要本地管理 token；执行时撤销未消费 Permit、取消在途任务、墓碑化 Event payload、清空 evidence refs 与 Projection 内容，同时保留哈希、ID、幂等键和 append-only 删除审计。
- 删除事务结束后 append-only trigger 恢复；测试验证 Outcome 与审计事件仍不能篡改。
- Console 可从 Episode 查看 Task、Runtime、Tool、Outcome、Notification，并可反馈、Replay 或发起授权删除。

## Console 验证

`agent-browser` 使用独立 session 打开真实本地 API/Console，选择历史不完整 Episode 后仍能以数据库主键补齐安全骨架，并展示 Task → Runtime → Tool → externally-verified Outcome → verified-completion Notification。清空浏览器日志后重新加载与点击，console 无 error/warning；这次检查同时修复了旧的部分 Projection 会产生空 ID、404 和 React key warning 的兼容问题。

截图：`docs/evidence/artifacts/outcome-console.png`。

## 自动化覆盖

`pnpm test`：12 个 test files / 35 个 tests，通过：

- Outcome 等级来源边界；
- 外部验证和原生回执 HMAC API；
- Notification SDK conformance、签名和幂等；
- fallback receipt ledger 与原生回执抑制；
- approval/high-risk escalation、quiet hours 与普通通知延迟；
- Feedback 幂等冲突；
- Retention tombstone、payload/evidence 清理、Projection 隐藏、Permit 撤销和审计 trigger；
- Task 完整时间线 API。

`pnpm lint`、`pnpm typecheck`、`pnpm build` 同步通过。

## 证据边界

- fallback receiver 是真实本地 HTTP 服务，但不是生产短信、邮件或推送供应商。
- `externally-verified` 来自受控签名 verifier；它证明验证边界与事实分级可运行，不代表真实第三方业务系统已经接入。
- Omi 实机与 production notification provider 仍不在本 checkpoint 的证明范围。
