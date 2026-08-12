# Checkpoint 1 · Bootstrap 证据

日期：2026-08-12（Asia/Shanghai）  
分支：`codex/mvp`  
状态：本机验证通过；Node 24 容器验证进行中

## 环境

- 本机：macOS 26.5.1（25F80），Apple Silicon `arm64`
- 本机 Node：v26.7.0；仅作为早期兼容性 smoke，不是指定 Node 24 基线证明
- pnpm：10.13.1
- 指定基线：`node:24-bookworm-slim`，镜像构建另行记录

## 已运行命令与结果

| 命令                                           | 实际结果 | 证据摘要                                                                     |
| ---------------------------------------------- | -------- | ---------------------------------------------------------------------------- |
| `pnpm install --offline --engine-strict=false` | PASS     | lockfile up to date；本机因 Node 26 正确显示 engine warning                  |
| `pnpm format:check`                            | PASS     | `All matched files use Prettier code style!`                                 |
| `pnpm lint`                                    | PASS     | ESLint 9.39.5，0 error                                                       |
| `pnpm typecheck`                               | PASS     | TypeScript 5.9.3 strict，0 error                                             |
| `pnpm test`                                    | PASS     | 3 files、4 tests；Contracts、SQLite migration、API health/readiness 全部通过 |
| `pnpm build`                                   | PASS     | API/Worker ESM build 与 React/Vite production build 通过                     |
| `pnpm db:migrate`                              | PASS     | SQLite migration runner 返回 `status: ok`；重复运行 `applied: []`            |
| `pnpm dev` + HTTP smoke                        | PASS     | API `4310`、Worker、Console `4173` 同时 ready                                |
| `GET /health`                                  | PASS     | `{"service":"wakeoncue-api","status":"ok","version":"0.1.0"}`                |
| `GET /ready`                                   | PASS     | `{"database":"ready","migrationsAppliedAtStartup":[],"status":"ready"}`      |
| Console `GET /`                                | PASS     | 返回 `<title>WakeOnCue Console`                                              |

## 尚未闭合

- 首次 Node 24 Docker 基础镜像拉取仍在进行；在镜像内 build 与 readiness 通过前，本文件不把 checkpoint 标为完成。
- Compose 的 API/Worker 共享 volume smoke 将在镜像完成后运行。
- 本 checkpoint 只证明工程骨架、契约注册、migration 和三个进程可启动；不证明 Replay、Attention、OpenClaw、Permit 或 Full-story 能力。
