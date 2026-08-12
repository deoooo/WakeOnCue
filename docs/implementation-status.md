# WakeOnCue 工程 MVP 实现状态

更新时间：2026-08-12

当前 checkpoint：2 · Replay-first（进行中）

分支：`codex/mvp`

## 已实现内容

- 创建 Node.js 26 / TypeScript strict / pnpm workspace；保留 `apps/` 与 `packages/` 架构边界。
- 建立 Cue Event、Attention Decision、Task Contract、Tool Attempt、Permit、Outcome、Notification 的版本化 TypeBox Schema Registry。
- 建立 SQLite 显式 migration，覆盖 Event Log、Projection、Task、Runtime、授权、Outcome、通知、Outbox 与 Delivery Ledger 所需表。
- 建立可启动的 Fastify API、后台 Worker 和 React/Vite Console；API/Worker 具备 migration、health/readiness 与优雅停机基础。
- 建立 Node 26 CI 质量门和 Compose 本地运行入口；Live Wake 环境默认关闭。

## 实际运行的验证

- `pnpm format:check`：PASS。
- `pnpm lint`：PASS，0 error。
- `pnpm typecheck`：PASS，TypeScript strict 0 error。
- `pnpm test`：PASS，3 个 test files、4 个 tests；覆盖版本化契约、SQLite migration 幂等和 API health/readiness。
- `pnpm build`：PASS；API/Worker ESM 与 React/Vite production build 成功。
- `pnpm db:migrate`：PASS；重复运行不重复应用 migration。
- `pnpm dev` 进程 smoke：PASS；API、Worker、Console 同时 ready，HTTP `/health`、`/ready` 和 Console HTML 均实际返回成功。
- 上述验证运行于 Node v26.7.0 / pnpm 10.13.1。用户于 2026-08-12 明确允许先使用 Node 26，并把 Docker 验证延后到 release audit；checkpoint 1 已闭合。

## 证据位置

- 公开契约：`packages/contracts/src/index.ts`
- 数据库 migration：`packages/storage-sqlite/src/migrations/001_initial.sql`
- API：`apps/api/src/server.ts`
- Worker：`apps/worker/src/main.ts`
- Console：`apps/console/`
- CI：`.github/workflows/ci.yml`
- Bootstrap 命令与输出摘要：`docs/evidence/bootstrap.md`

## 剩余工作

- 实现 checkpoint 2 的 append-only Event Log、签名 Webhook、Projection、dedup/outbox、Replay API/CLI 与 golden corpus。
- Checkpoint 3–8 尚未开始；见 Goal 的 Conversation Cue、OpenClaw、Approval、Outcome、Full-story 与 Release audit 要求。

## 已知风险或真正 blocker

- Docker/Compose 与 clean-clone smoke 尚未运行；按用户指示后置到 release audit，不能在此前声称容器路径已通过。
- OpenClaw 官方文档已确认 `/hooks/agent` 与 typed `before_tool_call`，但具体安装版本、激活回执、插件 manifest 与真实进程行为要在 checkpoint 4 通过源码/运行时检查后固定。
- Omi 实机凭证和设备尚未提供；按 Goal 将先使用版本化脱敏真实格式 fixture，且证据会明确标注不是线上实机证明。

## 文档冲突修订

- `docs/architecture.md` 原建议 Node.js 22 + JSON Schema/Zod；Goal 初始建议 Node.js 24，用户随后明确允许先以本机 Node 26 推进。现采用 Node.js 26 + Fastify + TypeBox/AJV，公开 Schema 仍是契约唯一事实来源，不改变领域或安全边界。
