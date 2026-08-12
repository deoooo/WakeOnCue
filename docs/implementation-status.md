# WakeOnCue 工程 MVP 实现状态

更新时间：2026-08-12  
当前 checkpoint：1 · Bootstrap（进行中）  
分支：`codex/mvp`

## 已实现内容

- 创建 Node.js 24 / TypeScript strict / pnpm workspace；保留 `apps/` 与 `packages/` 架构边界。
- 建立 Cue Event、Attention Decision、Task Contract、Tool Attempt、Permit、Outcome、Notification 的版本化 TypeBox Schema Registry。
- 建立 SQLite 显式 migration，覆盖 Event Log、Projection、Task、Runtime、授权、Outcome、通知、Outbox 与 Delivery Ledger 所需表。
- 建立可启动的 Fastify API、后台 Worker 和 React/Vite Console；API/Worker 具备 migration、health/readiness 与优雅停机基础。
- 建立 Node 24 CI 质量门和 Compose 本地运行入口；Live Wake 环境默认关闭。

## 实际运行的验证

- `pnpm format:check`：PASS。
- `pnpm lint`：PASS，0 error。
- `pnpm typecheck`：PASS，TypeScript strict 0 error。
- `pnpm test`：PASS，3 个 test files、4 个 tests；覆盖版本化契约、SQLite migration 幂等和 API health/readiness。
- `pnpm build`：PASS；API/Worker ESM 与 React/Vite production build 成功。
- `pnpm db:migrate`：PASS；重复运行不重复应用 migration。
- `pnpm dev` 进程 smoke：PASS；API、Worker、Console 同时 ready，HTTP `/health`、`/ready` 和 Console HTML 均实际返回成功。
- 上述本机验证运行于 Node v26.7.0，只作为兼容性 smoke；Node 24 Docker build 正在进行，未完成前不关闭 checkpoint 1。

## 证据位置

- 公开契约：`packages/contracts/src/index.ts`
- 数据库 migration：`packages/storage-sqlite/src/migrations/001_initial.sql`
- API：`apps/api/src/server.ts`
- Worker：`apps/worker/src/main.ts`
- Console：`apps/console/`
- CI：`.github/workflows/ci.yml`
- Bootstrap 命令与输出摘要：`docs/evidence/bootstrap.md`

## 剩余工作

- 完成 checkpoint 1 的 Node 24 镜像 build、Compose API/Worker smoke，记录真实结果后提交。
- Checkpoint 2–8 尚未开始；见 Goal 的 Replay、Conversation Cue、OpenClaw、Approval、Outcome、Full-story 与 Release audit 要求。

## 已知风险或真正 blocker

- 当前宿主默认 Node 为 v26.7.0；工程与 CI 锁定 Node 24，最终 clean-clone/real-openclaw 证明必须在 Node 24 环境运行。宿主 Node 26 仅可作为早期兼容性检查，不作为指定基线证据。
- OpenClaw 官方文档已确认 `/hooks/agent` 与 typed `before_tool_call`，但具体安装版本、激活回执、插件 manifest 与真实进程行为要在 checkpoint 4 通过源码/运行时检查后固定。
- Omi 实机凭证和设备尚未提供；按 Goal 将先使用版本化脱敏真实格式 fixture，且证据会明确标注不是线上实机证明。

## 文档冲突修订

- `docs/architecture.md` 原建议 Node.js 22 + JSON Schema/Zod；Goal 指定在无实测阻碍时采用 Node.js 24 LTS + Fastify + TypeBox/AJV 且 Schema 为公开契约唯一事实来源。已做最小技术基线修订，不改变领域或安全边界。
