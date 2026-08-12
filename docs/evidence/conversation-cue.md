# Checkpoint 3 · Conversation Cue 证据

日期：2026-08-12（Asia/Shanghai）

分支：`codex/mvp`

状态：PASS（Omi 使用版本化脱敏 fixture；不是线上实机证明）

## Omi 契约依据与证明边界

实现时于 2026-08-12 核对了 Omi 当前官方资料：

- [Integration Apps](https://docs.omi.me/doc/developer/apps/Integrations) 展示 completed conversation webhook 包含 conversation ID、时间、`transcript_segments`、speaker/is_user 与 structured action items。
- [List Conversations](https://docs.omi.me/api-reference/endpoint/conversations/list) 展示 completed conversation 与可选 transcript 的 Developer API 形态。
- [Storing Conversations & Memories](https://docs.omi.me/doc/developer/backend/StoringConversations) 说明 conversation、transcript、structured information 与 action item 的数据边界。

`packages/source-omi/fixtures/finalized-conversation.v1.json` 按上述公开字段制作，所有 ID、人物和文本均为人工脱敏测试数据。Adapter 输出只包含 provider-neutral conversation segments、action items、Evidence Ref 和最小化文本；没有复制音频，也没有把 Omi provider 类型泄漏到核心领域。

本 checkpoint 没有 Omi 设备或私有凭证，因此只证明 fixture/conformance 与本地入站链路，不证明线上 Omi webhook 或实机可用性。

## 自动化验证

| 命令                   | 实际结果 | 证据摘要                                   |
| ---------------------- | -------- | ------------------------------------------ |
| `pnpm lint`            | PASS     | ESLint 0 error                             |
| `pnpm typecheck`       | PASS     | TypeScript strict 0 error                  |
| `pnpm test`            | PASS     | 8 files、19 tests                          |
| `pnpm eval:attention`  | PASS     | 12 cases；Precision=1.0，Recall=1.0        |
| `pnpm bench:attention` | PASS     | 规则与确定性 Judge p95 均低于门槛          |
| `pnpm build`           | PASS     | API、Worker、Console production build 成功 |

离线 corpus 包含：明确承诺、绝对/相对 deadline、模糊愿望、假设、玩笑、说话人混淆、Prompt Injection、问题句和撤回。实际混淆矩阵为：

```json
{
  "cases": 12,
  "truePositive": 5,
  "falsePositive": 0,
  "trueNegative": 7,
  "falseNegative": 0,
  "precision": 1,
  "recall": 1,
  "status": "PASS"
}
```

这是小规模、受控、版本化离线 corpus 的能力证明，不代表真实用户 7 天 Shadow 数据。Shadow → Notify 所需的 7 天样本、误唤醒率和用户纠错记录仍然缺失，因此产品 gate 会拒绝开启 Notify/Wake。

## Attention 与 Observation 安全边界

- Hard Gate 检查来源事件、confidence、privacy purpose、subject speaker、撤回与 Prompt Injection。
- cheap signals 只提取承诺、deadline 和 recipient；不执行工具，也不生成内部 Chain-of-Thought。
- Structured Judge 只接受结构化 signal，输出必须匹配严格 Schema；超时、异常或两次无效结果一律降级为 `IGNORE / JUDGE_FAILED_SAFE`。
- `OBSERVE_MORE` 只生成 `conversation.recent_segments` 请求，包含 purpose、精确 data scope、max cost、120 秒 TTL 和 5 分钟 retention。
- Observation Broker 只注册 `readOnly: true` capability，并拒绝未注册 capability、超 scope、超 cost 和超 TTL 请求。
- `SHADOW` candidate 只落 Decision 与 timeline；不生成通知或 Runtime activation。
- Console 只能从 loopback 请求模式切换，且客户端不能提交 `gateEvidence`；服务端只读取内部 `source_gate_evidence` 评测记录。伪造 evidence 的 PUT 会被 Schema 拒绝。

## 本地真实进程烟测

在 quiet hours 关闭的受控 smoke 配置下运行：

```bash
WAKEONCUE_OMI_WEBHOOK_TOKEN=test-only-omi-token pnpm smoke:conversation
```

实际结果：

```json
{
  "inserted": true,
  "sourceMode": "SHADOW",
  "eventId": "evt_80f0a38522d400937826109d77",
  "episodeId": "ep_542bff2e10ad7ab69ee0e5843d",
  "decisionId": "dec_9b0aec3357b1a4c28cdf376f2a",
  "decision": "WAKE_AGENT",
  "reasonCodes": ["EXPLICIT_SUBJECT_COMMITMENT", "DEADLINE_PRESENT"],
  "disposition": "SHADOW_RECORDED",
  "commitment": "我周五之前把最终报价发给张三。",
  "deadline": "2026-08-14",
  "console": "reachable",
  "status": "PASS"
}
```

## Console 视觉与交互证据

浏览器自动化实际检查：页面非空、无 Vite error overlay、Episode 可点击、Decision reason codes 可见、Evidence Ref 可回溯、浏览器 errors 为空。首次检查发现模式保存的 PUT 被 CORS 预检拦截，补充允许方法后复测得到 `MODE_GATE_ENFORCED`。

- [Conversation Cue Console](./artifacts/conversation-cue-console.png)
- [Episode / Decision 时间线](./artifacts/conversation-cue-timeline.png)

截图中的 `WAKE_AGENT` 是 Shadow 决策候选；`SHADOW_RECORDED` 表明没有外部通知或 Agent activation。

## 性能证据

环境：Apple M1 Max、macOS arm64、Node v26.7.0；各路径 warmup 后运行 1,000 次：

```json
{
  "p95Ms": {
    "rules": 0.013082999999994627,
    "structuredJudge": 0.020875000000017963
  },
  "gatesMs": {
    "rules": 500,
    "structuredJudge": 5000
  },
  "judge": "deterministic-structured-judge/v1 (no external model or network)",
  "status": "PASS"
}
```

该基准只证明本机确定性实现，不代表外部模型延迟。真实 provider Judge 接入后必须单独重测 ≤5 s 门槛。
