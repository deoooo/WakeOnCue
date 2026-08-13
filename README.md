# WakeOnCue

> 现实事件驱动的 Agent 主动唤醒层  
> A proactive agent activation layer for real-world cues.

WakeOnCue 让 Agent 不必一直等待用户输入 Prompt。它接收来自 Omi、手机、Home Assistant、浏览器或 Webhook 的现实世界信号，将信号理解为可判断的 Cue，在正确时机选择：

<p align="center"><strong>IGNORE · OBSERVE_MORE · WAKE_AGENT</strong></p>

WakeOnCue 不实现通用 Agent，也不代替 OpenClaw、Pi Agent 等运行时执行工具。它负责的是两者之间缺失的一层：

~~~text
现实世界信号 → Cue 理解 → 主动触发决策 → 唤醒 Agent → 结果回流
~~~

## 核心边界

- **主动触发优先**：核心价值是从现实事件发现值得 Agent 介入的时机。
- **感知供应商可替换**：Omi、ASR、CV、IoT 和应用事件通过统一 Source Adapter 接入。
- **执行归 Agent**：规划、MCP/Tool 调用与执行循环仍由外部 Agent Runtime 负责。
- **敏感操作必须确认**：运行时在具体 Tool Attempt 形成后调用授权接口；没有一次性 Permit 就不能执行。
- **证据链是基础能力**：事件、决策、唤醒、授权和结果均可关联，但 Trace 不是产品主叙事。
- **结果必须闭环**：执行状态、验证结果、通知回执和用户反馈重新成为事件。

## 文档

- [系统架构](docs/architecture.md)
- [MVP 设计](docs/mvp.md)
- [可直接交给 Codex 长期执行的 MVP Goal Prompt](MVP_GOAL_PROMPT.md)
- [可交互 HTML 架构图](docs/architecture.html)

## MVP

第一版只证明一件事：

> 一段现实对话或外部事件，可以在没有新 Prompt 的情况下，低打扰地形成一个有证据的 Agent 任务；敏感操作会在执行前向用户确认，结果可以回到同一条任务时间线。

首批范围：

- Source：通用 Webhook + Omi transcript；
- 决策：规则、去重、冷却和结构化 LLM Judge；
- 输出：Shadow、通知或唤醒一个 Agent Runtime；
- 安全：只读自动执行，外发/写入/设备控制逐次确认；
- 产品面：Cue 时间线、Wake 决策、审批和执行结果。

## 项目状态

工程 MVP 正在按 `docs/implementation-status.md` 中的可运行 checkpoint 推进。仓库暂为私有，尚未承诺稳定 API；生产 Live Wake 默认关闭。

## 本地开发

当前工程基线为 Node.js 26 与 pnpm 10：

~~~bash
corepack enable
# 可选：需要覆盖默认本地配置或接真实 Adapter 时再复制
cp .env.example .env
pnpm install --frozen-lockfile
pnpm db:migrate
pnpm dev
~~~

默认地址：API `http://127.0.0.1:4310`，Console `http://127.0.0.1:4173`。健康检查：

~~~bash
curl --fail http://127.0.0.1:4310/health
curl --fail http://127.0.0.1:4310/ready
~~~

质量门：

~~~bash
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test
pnpm build
~~~

### 真实 OpenClaw E2E

WakeOnCue 日常开发继续使用 Node 26。当前固定验证的 OpenClaw `2026.7.1-2` 不支持 Node 26，因此只给 OpenClaw 进程使用 `n` 安装在用户目录中的 Node 24，不修改全局 Node，也不要求 Docker：

~~~bash
N_PREFIX="$HOME/.local/n" n 24.19.0
mkdir -p .runtime/openclaw-cli
PATH="$HOME/.local/n/bin:$PATH" npm install \
  --prefix .runtime/openclaw-cli \
  --ignore-scripts --no-audit --no-fund \
  openclaw@2026.7.1-2

export WAKEONCUE_OPENCLAW_BIN="$PWD/.runtime/openclaw-cli/node_modules/.bin/openclaw"
export WAKEONCUE_OPENCLAW_NODE_BIN_DIR="$HOME/.local/n/bin"
pnpm test:e2e:openclaw
~~~

E2E 会创建隔离的 `.runtime/openclaw-e2e` 状态，强制 Gateway 绑定 loopback，关闭渠道，并通过 OpenClaw 官方 CLI 把现有 `~/.openclaw` 中的 portable static auth profile 导入隔离的 SQLite auth store；中间 JSON 副本随后删除，密钥不会输出。也可用 `WAKEONCUE_OPENCLAW_SOURCE_STATE_DIR` 指向另一份来源状态。

这条验证使用版本化、脱敏的 Omi fixture，但启动的 OpenClaw、模型请求、plugin hook、Tool Attempt 和签名 callback 都是真实运行。它证明工程集成，不代表 Omi 设备线上数据或生产 7 天 canary；生产 Live Wake 仍默认关闭。

Compose 路径：

~~~bash
docker compose up --build
~~~

当前实际验证、证据与剩余项见 [工程 MVP 实现状态](docs/implementation-status.md)。

## 名称

**WakeOnCue** 表达的是“在现实 Cue 出现时唤醒合适的 Agent”。

<strong>Wake 不等于 Execute。</strong> 主动唤醒不会绕过用户授权。
