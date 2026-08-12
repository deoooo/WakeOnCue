# Checkpoint 2 · Replay-first 证据

日期：2026-08-12（Asia/Shanghai）

分支：`codex/mvp`

状态：PASS（本机 Node 26 / pnpm；Docker 路径不在本 checkpoint 证明范围）

## 实现边界

- `packages/source-webhook`：通用 Webhook v1 Schema、HMAC-SHA256 验签、300 秒抗重放时间窗、确定性 `CueEvent` 映射。
- `packages/storage-sqlite`：Event 与原始 payload、outbox 同事务写入；事件表由 trigger 禁止 UPDATE/DELETE；相同幂等键不同 payload 返回冲突。
- `packages/core`：按事件标识去重、按 subject/correlation 聚合 Episode，保留 deadline 变更历史并生成 canonical digest。
- Worker：消费 `event.project` outbox，写入 Episode projection 与 delivery ledger。
- `POST /v1/replays` 与 `pnpm replay`：从 append-only Event Log 或版本化 fixture 重建投影。

## 自动化验证

| 命令                | 实际结果 | 证据摘要                            |
| ------------------- | -------- | ----------------------------------- |
| `pnpm format:check` | PASS     | Prettier 0 drift                    |
| `pnpm lint`         | PASS     | ESLint 0 error                      |
| `pnpm typecheck`    | PASS     | TypeScript strict 0 error           |
| `pnpm test`         | PASS     | 6 files、10 tests                   |
| `pnpm replay`       | PASS     | golden corpus digest 与固定预期一致 |

Golden corpus `deadline-change-and-duplicate` 的实际输出：

```json
{
  "digest": "sha256:e86c02530ea72478d32cce3c52425b0b87274598e67b3cc5cfdbd7f0ffad7487",
  "eventCount": 2,
  "duplicateCount": 1,
  "episodeCount": 1,
  "deadlineHistory": ["2026-08-14", "2026-08-15"],
  "status": "PASS"
}
```

## 真实进程烟测

启动 API、Worker 与 Console 后，运行：

```bash
WAKEONCUE_WEBHOOK_SECRET=test-only-smoke-secret pnpm smoke:webhook
```

首次进程烟测实际观测：第 1 次响应为 202，随后 9 次为 200 去重响应；Worker 日志记录 `processed: 1`。独立复跑后 10 次全部命中持久化去重，并得到：

```json
{
  "attempts": 10,
  "inserted": 0,
  "duplicateResponses": 10,
  "eventId": "evt_6134f196739825c46272d2c4f8",
  "episodeId": "ep_f3b9382daff78cad7f9a70353b",
  "replayDigest": "sha256:19938525e9a965171f4998cd2ec10656f3505e4cabdff32c5bedf3024e6de8d9",
  "projectedEventCount": 1,
  "status": "PASS"
}
```

这证明了本机真实 HTTP 请求、SQLite 持久化、Worker outbox 消费和 Replay 读取链路；它不是 Docker、生产环境或外部 SaaS 的运行证明。

## 安全与失败语义

- 缺失/错误签名返回 401，且不写 Event Log 或 quarantine。
- 超出时间窗的签名按重放攻击拒绝。
- 验签成功但 JSON/Schema 无效的载荷进入 `ingress_errors`；仅保留 payload digest 与结构化错误，不保存原始正文。
- Event Log 的 UPDATE/DELETE 由数据库 trigger 阻止。
- 同一 idempotency key 携带不同 payload 返回明确冲突，不静默覆盖。
