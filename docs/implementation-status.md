# WakeOnCue 工程 MVP 实现状态

更新时间：2026-08-12

当前 checkpoint：4 · Agent Wake（准备中）

分支：`codex/mvp`

## 已实现内容

- 创建 Node.js 26 / TypeScript strict / pnpm workspace；保留 `apps/` 与 `packages/` 架构边界。
- 建立 Cue Event、Attention Decision、Task Contract、Tool Attempt、Permit、Outcome、Notification 的版本化 TypeBox Schema Registry。
- 建立 SQLite 显式 migration，覆盖 Event Log、Projection、Task、Runtime、授权、Outcome、通知、Outbox 与 Delivery Ledger 所需表。
- 建立可启动的 Fastify API、后台 Worker 和 React/Vite Console；API/Worker 具备 migration、health/readiness 与优雅停机基础。
- 建立 Node 26 CI 质量门和 Compose 本地运行入口；Live Wake 环境默认关闭。
- 完成 Replay-first 主干：append-only Event Log、原始载荷审计、签名 Webhook、确定性 Projection、transactional outbox、delivery ledger、Replay API/CLI 与版本化 golden corpus。
- Webhook 在 JSON 解析前验证 HMAC 和时间窗；认证失败不落库，合法但不符合 Schema 的请求只进入脱敏 quarantine。
- Event ID、Episode ID 与 projection digest 均由 canonical payload 确定性派生；同一事件重复投递不会改变投影摘要。
- 完成 Omi finalized conversation Adapter：以 Omi 当前公开 conversation/memory webhook 字段为输入，映射为 provider-neutral `CueEvent`；版本化 fixture 不包含真实用户、设备或凭证。
- 完成 conversation 提取与 Attention Cascade：subject speaker、承诺、对象、deadline、撤回、Prompt Injection、hard gate、quiet hours、daily budget、semantic cooldown、Structured Judge 与 bounded Observation。
- 新 Source + Cue Type 默认 `SHADOW`；`NOTIFY`/`WAKE` 必须提交可计算 gate evidence，生产 Live Wake 仍未开启。
- Worker 从 outbox 形成 `Episode → AttentionDecision`，持久化提取实体、Decision 与 disposition；Shadow candidate 不产生通知或 Runtime 副作用。
- Console 已接入真实 Episode/Decision API，可查看 reason codes、策略版本、证据引用与连续时间线，并能看到模式门槛拒绝原因。

## 实际运行的验证

- `pnpm format:check`：PASS。
- `pnpm lint`：PASS，0 error。
- `pnpm typecheck`：PASS，TypeScript strict 0 error。
- `pnpm test`：PASS，6 个 test files、10 个 tests；覆盖版本化契约、确定性 replay、Webhook 验签、SQLite append-only/idempotency/outbox/projection 与 API 集成。
- `pnpm build`：PASS；API/Worker ESM 与 React/Vite production build 成功。
- `pnpm db:migrate`：PASS；重复运行不重复应用 migration。
- `pnpm dev` 进程 smoke：PASS；API、Worker、Console 同时 ready，HTTP `/health`、`/ready` 和 Console HTML 均实际返回成功。
- 上述验证运行于 Node v26.7.0 / pnpm 10.13.1。用户于 2026-08-12 明确允许先使用 Node 26，并把 Docker 验证延后到 release audit；checkpoint 1 已闭合。
- `pnpm replay`：PASS；固定 corpus 的 digest 为 `sha256:e86c02530ea72478d32cce3c52425b0b87274598e67b3cc5cfdbd7f0ffad7487`，2 个唯一事件、1 个重复事件合并为 1 个 Episode，保留两次 deadline 历史。
- 真实本地进程 `pnpm dev` + `pnpm smoke:webhook`：PASS；同一签名请求投递 10 次只产生 1 个 eventId 和 1 个 Episode，Worker 实际消费 outbox。第二次独立运行 10/10 均命中持久化去重，Replay 与 Episode 读取仍 PASS。
- `pnpm test`（checkpoint 3）：PASS，8 个 test files、19 个 tests；新增 Omi conformance、Attention corpus/gates/fail-closed/Observation、mode gate 和 entity projection 覆盖。
- `pnpm eval:attention`：PASS；12 个脱敏样本中 TP=5、FP=0、TN=7、FN=0，Precision=100%、Recall=100%。这是版本化离线 fixture 结果，不是 7 天真实 Shadow 指标。
- `pnpm bench:attention`：PASS；Apple M1 Max / Node v26.7.0，1,000 次迭代，规则路径 p95=0.0131 ms、确定性 Judge 路径 p95=0.0209 ms。此 Judge 不访问付费模型或网络。
- `pnpm smoke:conversation`：PASS；本地真实 API/Worker/SQLite 产生 `WAKE_AGENT + SHADOW_RECORDED`，提取“我周五之前把最终报价发给张三。”与 `2026-08-14`，Console HTTP 可达。
- `agent-browser` Console 检查：PASS；页面有内容、无 Vite overlay、无浏览器错误，Episode 点击后 reason codes 与 evidence chain 可见，Notify 配置因缺少 7 天真实 gate evidence 被明确拒绝。该检查发现并修复了 PUT CORS 预检缺失。

## 证据位置

- 公开契约：`packages/contracts/src/index.ts`
- 数据库 migration：`packages/storage-sqlite/src/migrations/001_initial.sql`
- API：`apps/api/src/server.ts`
- Worker：`apps/worker/src/main.ts`
- Console：`apps/console/`
- CI：`.github/workflows/ci.yml`
- Bootstrap 命令与输出摘要：`docs/evidence/bootstrap.md`
- Replay-first 命令、输出与证据边界：`docs/evidence/replay-first.md`
- Conversation Cue、Omi fixture、离线指标、烟测与 UI 截图：`docs/evidence/conversation-cue.md`

## 剩余工作

- 实现 checkpoint 4 的 Task Contract、Runtime SDK/Webhook、真实 OpenClaw activation、状态回收和 UNKNOWN reconciliation。
- Checkpoint 5–8 尚未开始；见 Goal 的 Approval、Outcome、Full-story 与 Release audit 要求。

## 已知风险或真正 blocker

- Docker/Compose 与 clean-clone smoke 尚未运行；按用户指示后置到 release audit，不能在此前声称容器路径已通过。
- OpenClaw 官方文档已确认 `/hooks/agent` 与 typed `before_tool_call`，但具体安装版本、激活回执、插件 manifest 与真实进程行为要在 checkpoint 4 通过源码/运行时检查后固定。
- Omi 实机凭证和设备尚未提供；按 Goal 将先使用版本化脱敏真实格式 fixture，且证据会明确标注不是线上实机证明。
- Omi 官方 webhook 文档展示 payload 但未声明原生请求签名；当前本地入站 API 额外要求专用 Bearer token。若直连形态不能配置该 Header，需在 release audit 前固定受认证反向代理或 Developer API polling 形态，不能退化为未认证公网 endpoint。

## 文档冲突修订

- `docs/architecture.md` 原建议 Node.js 22 + JSON Schema/Zod；Goal 初始建议 Node.js 24，用户随后明确允许先以本机 Node 26 推进。现采用 Node.js 26 + Fastify + TypeBox/AJV，公开 Schema 仍是契约唯一事实来源，不改变领域或安全边界。
