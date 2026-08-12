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

当前处于架构与 MVP 定义阶段。仓库暂为私有，尚未承诺稳定 API。

## 名称

**WakeOnCue** 表达的是“在现实 Cue 出现时唤醒合适的 Agent”。

<strong>Wake 不等于 Execute。</strong> 主动唤醒不会绕过用户授权。
