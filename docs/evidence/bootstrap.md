# Checkpoint 1 · Bootstrap 证据

日期：2026-08-12（Asia/Shanghai）

分支：`codex/mvp`

状态：本机 Node 26 / pnpm 验证通过；Docker 延后到 release audit

## 环境

- 本机：macOS 26.5.1（25F80），Apple Silicon `arm64`
- 本机 Node：v26.7.0
- pnpm：10.13.1
- 用户于 2026-08-12 明确允许先按 Node 26 与本机 pnpm 推进，Docker 不作为当前 checkpoint blocker

## 已运行命令与结果

| 命令                     | 实际结果 | 证据摘要                                                                     |
| ------------------------ | -------- | ---------------------------------------------------------------------------- |
| `pnpm install --offline` | PASS     | lockfile up to date                                                          |
| `pnpm format:check`      | PASS     | `All matched files use Prettier code style!`                                 |
| `pnpm lint`              | PASS     | ESLint 9.39.5，0 error                                                       |
| `pnpm typecheck`         | PASS     | TypeScript 5.9.3 strict，0 error                                             |
| `pnpm test`              | PASS     | 3 files、4 tests；Contracts、SQLite migration、API health/readiness 全部通过 |
| `pnpm build`             | PASS     | API/Worker ESM build 与 React/Vite production build 通过                     |
| `pnpm db:migrate`        | PASS     | SQLite migration runner 返回 `status: ok`；重复运行 `applied: []`            |
| `pnpm dev` + HTTP smoke  | PASS     | API `4310`、Worker、Console `4173` 同时 ready                                |
| `GET /health`            | PASS     | `{"service":"wakeoncue-api","status":"ok","version":"0.1.0"}`                |
| `GET /ready`             | PASS     | `{"database":"ready","migrationsAppliedAtStartup":[],"status":"ready"}`      |
| Console `GET /`          | PASS     | 返回 `<title>WakeOnCue Console`                                              |

## 后置验证

- Docker/Compose 与 clean-clone smoke 按用户指示延后到 release audit，不阻塞 Replay-first 开发。
- 本 checkpoint 只证明工程骨架、契约注册、migration 和三个进程可启动；不证明 Replay、Attention、OpenClaw、Permit 或 Full-story 能力。
