# Checkpoint 4 · Real OpenClaw Agent Wake

验证日期：2026-08-13

实现提交：`6749371`

## 结论

Checkpoint 4 的真实 Runtime 路径通过。WakeOnCue API/Worker 使用 Node `v26.7.0`；只有 OpenClaw 子进程通过本地 `n` 路径使用 Node `v24.19.0`，没有切换系统默认 Node。固定运行时为 `OpenClaw 2026.7.1-2 (0790d9f)`。

真实链路为：脱敏 Omi fixture → 签名 Webhook → Cue/Event/Decision → Task Contract → Delivery Ledger → OpenClaw `/hooks/agent` → 真实模型回合 → typed plugin callbacks → WakeOnCue Runtime 状态。

## 可复现命令

```bash
WAKEONCUE_OPENCLAW_BIN=/Users/deo/.cache/wakeoncue-openclaw/runtime/node_modules/.bin/openclaw \
WAKEONCUE_OPENCLAW_NODE_BIN_DIR=/Users/deo/.local/n/bin \
pnpm test:e2e:openclaw
```

结果：`PASS`，耗时 72,219 ms。脱敏摘要见 `docs/evidence/artifacts/real-openclaw-e2e-2026-08-13.json`。

## 运行证据

- OpenClaw `/health` 成功，启动日志确认加载 `wakeoncue-guard` 插件。
- activation run 与 Agent run 使用不同 ID，避免把 HTTP 激活回执误当成模型回合 ID。
- 签名回调顺序为 `RUNNING → SUCCEEDED`；回调先进入 append-only event，再更新 projection。
- OpenClaw session 证明模型回合真实完成；Agent 自主选择了 9 次工具调用，9 次均被插件的 fail-closed PEP 边界拦截。
- Task Contract 只包含 outcome、constraints、success criteria、evidence 和 capability scope，不包含预先编排的 tool steps。
- 重复 Cue 没有新增 Event/Task；重复 activation 返回同一个 run ID；回调仍为 2 条；外部重复副作用为 0。
- 中断后的激活与超时运行会进入 `UNKNOWN`/reconciliation，不盲目重试外部调用。

原始 result、OpenClaw/API/Worker 日志和 OpenClaw session 保留在被 `.gitignore` 排除的本地 `.runtime/` 中。提交的脱敏摘要记录了每个原始文件的 SHA-256，可用于同机审计，又不会提交凭证或完整会话内容。

## 失败记录与修正

真实验证没有把失败运行计为成功：

1. 首次运行发现当前 OpenClaw 凭证存储在 Agent SQLite，而不是旧 JSON；改为官方 `models auth --agent main paste-api-key` 导入流程，导入中间文件随即删除。
2. 第二次运行发现 `/hooks/agent` activation ID 与 typed hook `ctx.runId` 不同；数据模型拆分为 `externalRunId` 与 `agentRunId`。
3. 第三次运行发现 HTTP 激活 timeout 与 Agent turn timeout 被混用；拆分为短 HTTP timeout 和限定的 120 秒模型回合 timeout。
4. 提交后第一次复跑发现 `/health` 不提供插件列表，尽管运行日志已确认插件加载；验证改为健康 endpoint 与插件启动日志两个独立信号，随后在提交 `6749371` 上复跑通过。

## 证据边界

- 输入是版本化脱敏 Omi 格式 fixture，不是 Omi 设备在线实测。
- OpenClaw 进程、固定版本插件、模型供应商调用和模型回合是真实的，不是 fake runtime 或 scripted model response。
- Wake gate 是只用于此次 E2E 的临时数据库受控证据，不代表已获得 7 天真实 Shadow 指标。
- `SUCCEEDED` 在此 checkpoint 仅表示 Agent turn 完成；它不等于外部任务结果已验证。Outcome 的 `reported / tool-confirmed / externally-verified` 分级属于后续 checkpoint。
- 生产 Live Wake 仍默认关闭；这不是 production canary 证明。

## 参考契约

- [Omi Integration Apps](https://docs.omi.me/doc/developer/apps/Integrations)
- [Omi Conversations API](https://docs.omi.me/api-reference/endpoint/conversations/list)
- [Omi Storing Conversations](https://docs.omi.me/doc/developer/backend/StoringConversations)
- [OpenClaw Webhooks](https://docs.openclaw.ai/webhook)
- [OpenClaw Plugin Hooks](https://docs.openclaw.ai/plugins/hooks)
- [OpenClaw Plugin Manifest](https://docs.openclaw.ai/plugins/manifest)
- [OpenClaw Building Plugins](https://docs.openclaw.ai/plugins/building-plugins)
- [OpenClaw Agent Loop](https://docs.openclaw.ai/agent-loop)
