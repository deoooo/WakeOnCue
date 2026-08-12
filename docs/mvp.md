# WakeOnCue MVP 设计

状态：Draft 0.1  
目标周期：8 周参考计划  
更新时间：2026-08-12

## 1. MVP 要验证什么

### 产品假设

用户在现实对话和环境中已经表达了大量承诺、需求和异常，但现有 Agent 通常只有收到 Prompt 才开始工作。如果系统能够低误触地识别其中少数高价值 Cue，主动唤醒用户现有的 Agent，并在敏感操作前确认，用户会愿意持续开启这条链路。

### 一句话验收

> 一段现实对话或外部事件，在用户没有再次输入 Prompt 的情况下形成可解释的 Wake；外部 Agent 完成规划，敏感操作得到逐次确认，结果回到同一条时间线。

### MVP 不是

- 通用个人助理；
- 新的 Agent Runtime；
- 自研录音、ASR、CV 或硬件平台；
- “听到什么就自动做什么”的全自动系统；
- 多 Agent 编排平台；
- 用大量 Source 数量证明价值的集成项目。

## 2. 目标用户与场景

### 首批用户

- 已经使用 OpenClaw、Pi Agent 或可通过 Webhook 唤醒 Agent 的技术用户；
- 愿意连接 Omi 或发送结构化 Webhook；
- 对现实对话中的承诺、跟进和异常提醒有明确需求；
- 接受先运行 Shadow Mode，再逐步开启主动通知和执行。

### 主场景：对话承诺

用户在交谈中说：

> “我周五之前把最终报价发给张三。”

系统应该：

1. Omi Adapter 接收到最终转写片段；
2. 合并同一段对话，提取承诺、对象和截止时间；
3. 判断它不是重复事件，也没有被用户撤回；
4. 在 Shadow Mode 中形成 Wake Candidate；
5. 开启 Live 后生成 Task Contract 并唤醒指定 Agent；
6. Agent 可以查询联系人、读取报价和生成草稿；
7. Agent 尝试外发时，用户看到精确收件人、附件和摘要；
8. 用户批准一次，Runtime 执行；
9. 发送结果被工具或外部回执验证；
10. 用户从通知进入同一条 Cue / Task 时间线。

### 辅场景：结构化异常

Home Assistant 或业务 Webhook 上报：

> “办公室门在静默时段持续开启 10 分钟。”

系统应该先合并重复传感器事件，再根据规则选择通知、补充查询当前状态，或者唤醒只读调查 Agent；MVP 不允许自动控制门锁。

## 3. MVP 范围

### 3.1 必做

#### Source

- 通用签名 Webhook；
- Omi finalized transcript / conversation adapter；
- Source Adapter SDK 与 conformance tests；
- Provider payload 到 Cue Event 的映射和幂等。

#### Cue Core

- Cue Event Schema Registry；
- SQLite append-only Event Log；
- Episode Builder：dedup、debounce、merge；
- 简单实体和时间提取；
- World State Projection；
- Replay API 和 CLI。

#### Attention

- Hard Gate；
- 明确承诺、截止时间和结构化异常规则；
- cooldown 与 quiet hours；
- 用户每日 Wake/通知预算；
- 结构化 Judge；
- <code>IGNORE | OBSERVE_MORE | WAKE_AGENT</code>；
- Shadow Mode。

#### Wake

- Task Contract；
- transactional Wake Outbox；
- 一个通用 Runtime Webhook Adapter；
- 在真实联调中选择 OpenClaw 或 Pi Agent 其中一个作为首个官方 Adapter；
- Runtime 状态回调；
- 超时、取消和 <code>UNKNOWN</code> reconciliation。

#### Authorization

- Tool Attempt API；
- 默认风险分类；
- <code>ALLOW | APPROVE_ONCE | DENY</code>；
- Web 审批页；
- 一次性 Permit；
- Runtime Adapter pre-tool interception conformance test。

#### Outcome & Notification

- Outcome API；
- reported / tool-confirmed / externally-verified 可信等级；
- Runtime 原生消息回执关联；
- 一个 fallback 通知渠道；
- 结果去重；
- Cue / Task 时间线。

#### Operations

- OpenTelemetry trace；
- 结构化业务关联 ID；
- Event、Decision、Task、Attempt、Permit、Outcome 查询；
- 数据保留和删除；
- 本地备份与恢复说明；
- replay corpus 和离线评测脚本。

### 3.2 可延后

- Home Assistant 官方 Adapter；
- 多用户和多租户；
- 手机端 App；
- 多 Runtime 智能路由；
- 语义向量检索；
- 高级用户习惯学习；
- 多通知渠道编排；
- PostgreSQL；
- 远端消息 Broker；
- A2A / Agent Mesh。

### 3.3 明确不做

- 自研 ASR/CV 模型；
- 保存完整持续录音；
- 任意相机浏览和主动扫描；
- 支付、购买、删除和设备控制；
- Attention Engine 直接调用 MCP；
- 没有具体 Tool Attempt 的宽泛永久授权；
- 未经 Shadow 评测直接默认开启 Live Wake；
- 外部运行结果不确定时自动重复执行。

## 4. 用户体验

### 4.1 三种运行模式

| 模式 | 行为 | 默认 |
|---|---|---|
| Shadow | 记录系统本来会如何判断，不通知、不唤醒 | 新 Source 默认 |
| Notify | 对高置信 Cue 通知用户，由用户决定是否唤醒 Agent | Shadow 达标后 |
| Wake | 自动唤醒 Agent；敏感 Tool Attempt 仍需确认 | 用户显式开启 |

模式按 Source + Cue Type 配置，不能只设一个全局开关。

### 4.2 时间线

每个 Episode 显示一条连续时间线：

~~~text
Cue received
→ Episode merged
→ Wake decision
→ Agent activated
→ Tool attempt
→ User approval
→ Tool result
→ Outcome verified
→ User notified
→ Feedback
~~~

用户看到的是：

- 系统理解了什么；
- 为什么打扰；
- 使用了哪些证据；
- Agent 准备做什么；
- 需要确认的精确影响；
- 最后是否真的完成。

默认不展示模型内部 Chain-of-Thought。

### 4.3 审批卡

审批卡必须包含：

- Agent 和任务目标；
- 工具名称的用户语言表达；
- 收件人、目标系统或设备；
- 将要发送、修改或公开的数据摘要；
- 是否可逆；
- 预计费用；
- 一次批准、拒绝两个主要动作；
- 参数变化后旧批准自动失效的说明。

MVP 不提供“永远允许此工具”按钮。

### 4.4 通知

通知分四类：

1. 审批请求；
2. 高风险失败或状态未知；
3. 已验证完成；
4. 可合并的普通摘要。

审批和高风险失败可突破普通打扰预算，但仍必须去重；普通成功通知遵循 quiet hours 和每日预算。

## 5. 功能流程

### 5.1 Ingestion

~~~text
verify signature
→ validate provider payload
→ map to Cue Event
→ redact/minimize
→ compute idempotency key
→ append Event Log
→ enqueue projector
~~~

失败时：

- 鉴权失败：拒绝且不落业务数据；
- Schema 错误：进入隔离错误记录；
- 重复事件：返回原 eventId；
- Provider 超时重试：不会产生重复 Episode。

### 5.2 Cue Decision

~~~text
event
→ project fact
→ merge episode
→ hard gates
→ deterministic signals
→ novelty/cooldown/budget
→ optional bounded observation
→ structured judge
→ decision record
→ ignore or wake outbox
~~~

Judge 输出必须匹配 Schema，最多重试一次；仍无效则安全降级到 Shadow/Ignore，并记录原因。

### 5.3 Wake

~~~text
decision + world snapshot
→ Wake Policy
→ Task Contract
→ persist task + outbox atomically
→ Runtime Adapter.activate
→ callback / poll
→ reconcile state
~~~

Adapter 在激活超时后先查询幂等键，不直接再次激活。

### 5.4 Sensitive Tool Attempt

~~~text
Agent plans concrete tool call
→ Runtime Guard pauses
→ POST Tool Attempt
→ PDP evaluates
→ ask user when required
→ issue one-time Permit
→ Runtime Guard validates exact digest
→ execute once
→ report Tool Result
~~~

如果 Runtime 不能暂停具体工具调用，MVP 对该 Runtime 只开放只读工具。

### 5.5 Outcome

~~~text
runtime report
→ normalize outcome
→ verify against success criteria
→ classify confidence
→ deduplicate native/fallback notification
→ update timeline
→ append feedback
~~~

“Agent 说完成了”只能是 <code>reported</code>，不能自动标记为已验证完成。

## 6. MVP API

所有写入 API 要求 <code>Idempotency-Key</code>。

### Source

~~~text
POST /v1/events
POST /v1/sources/webhook/{sourceId}
POST /v1/sources/omi/{sourceId}
GET  /v1/events/{eventId}
~~~

### Cue & Decision

~~~text
GET  /v1/episodes/{episodeId}
POST /v1/episodes/{episodeId}/decide
POST /v1/observations
GET  /v1/decisions/{decisionId}
POST /v1/replays
~~~

### Task & Runtime

~~~text
POST /v1/tasks/{taskId}/activate
POST /v1/runtime-runs/{runId}/events
GET  /v1/runtime-runs/{runId}
POST /v1/runtime-runs/{runId}/cancel
~~~

### Authorization

~~~text
POST /v1/tool-attempts
POST /v1/tool-attempts/{attemptId}/approve
POST /v1/tool-attempts/{attemptId}/deny
POST /v1/permits/{permitId}/consume
~~~

### Outcome & Feedback

~~~text
POST /v1/outcomes
POST /v1/notifications/{notificationId}/receipts
POST /v1/tasks/{taskId}/feedback
GET  /v1/tasks/{taskId}/timeline
~~~

## 7. 数据模型

MVP 至少包含：

| 表 | 用途 |
|---|---|
| <code>events</code> | append-only Cue 和生命周期事实 |
| <code>event_payloads</code> | 可选加密 payload 或外部 evidence ref |
| <code>episodes</code> | 当前 Episode 投影 |
| <code>entities</code> | 当前实体投影 |
| <code>decisions</code> | Attention/Wake 结构化记录 |
| <code>observation_requests</code> | 有界补充观察 |
| <code>tasks</code> | Task Contract 当前视图 |
| <code>runtime_runs</code> | 外部 Runtime 映射与状态 |
| <code>tool_attempts</code> | Agent 提交的具体敏感操作 |
| <code>permits</code> | 一次性授权和消费状态 |
| <code>outcomes</code> | 执行结果与验证等级 |
| <code>notifications</code> | 投递和去重 |
| <code>feedback</code> | 接受、忽略、拒绝、关闭主题 |
| <code>outbox</code> | 事务副作用队列 |
| <code>deliveries</code> | 外部派发幂等和回执 |

Event Log 保留事实；episodes、entities、tasks 和 timeline 都是可重建投影。

## 8. 安全与隐私

### 默认原则

- Source 最小权限；
- 原始媒体默认不复制；
- 保存证据引用和必要文本片段；
- 每个 Source 独立签名密钥；
- 敏感字段静态加密；
- UI 与日志默认脱敏；
- Observation 必须符合最初授权目的；
- 删除请求产生 tombstone 并清理 payload/projection；
- 运行时凭证只存在 Adapter Secret Store；
- Runtime Policy Token 有范围和短 TTL；
- 所有外部写操作都要求参数级审批。

### 威胁模型 MVP 必测

- Webhook 重放；
- Provider 伪造和事件污染；
- 转写内容中的 Prompt Injection；
- LLM 生成不存在的证据引用；
- Runtime 绕过 Tool Attempt；
- 批准后更换参数；
- Permit 重放；
- 外部执行超时导致重复副作用；
- 通知内容泄漏敏感数据；
- 用户撤销授权后的在途任务。

## 9. 评测设计

### Replay Corpus

每条样本不是孤立文本，而是一段带时间的事件流：

~~~text
events[]
acceptableWakeWindow
expectedDecision
allowedObservations[]
forbiddenActions[]
expectedReasonCodes[]
~~~

数据集至少包含：

- 明确承诺；
- 模糊愿望；
- 玩笑和假设；
- 已撤回承诺；
- 重复提及；
- 多人对话中的说话人混淆；
- 截止时间变更；
- quiet hours；
- 相同事件来自两个 Source；
- 注入式恶意文本；
- Runtime 成功、失败、超时和未知结果。

### 核心指标

| 指标 | MVP 门槛 |
|---|---:|
| 重复外部副作用 | 0 |
| 未授权敏感 Tool Attempt | 0 |
| Permit 参数不一致仍可执行 | 0 |
| Replay 同版本决策一致率 | 100% |
| Shadow 数据可完整回溯 | 100% |
| 明确承诺 Precision | ≥ 90% |
| 明确承诺 Recall | ≥ 75% |
| 每用户每日误唤醒 | ≤ 0.2 |
| p95 规则路径决策延迟 | ≤ 500 ms |
| p95 含 Judge 决策延迟 | ≤ 5 s |
| 每千输入事件 Judge 调用 | 可观测且设预算，不追求越多越好 |

Precision 优先于 Recall。主动产品过早打扰一次，比漏掉一个低价值 Cue 更伤害信任。

## 10. 分阶段计划

### 第 1–2 周：Replay-first

- contracts；
- SQLite Event Log；
- generic webhook；
- projection、dedup、cooldown；
- replay CLI；
- Shadow 决策；
- golden fixtures。

退出条件：同一事件流重复回放，不产生重复 Event、Decision 或副作用。

### 第 3–4 周：Conversation Cue

- Omi Adapter；
- commitment / deadline extraction；
- Episode merge；
- structured Judge；
- quiet hours 和 budget；
- Cue 时间线。

退出条件：离线语料达到 Precision 门槛，且能解释每个 Wake/Ignore。

### 第 5–6 周：Agent Wake

- Task Contract；
- Runtime Webhook Adapter；
- 首个 OpenClaw 或 Pi 官方 Adapter；
- wake outbox；
- Runtime 状态回收；
- unknown reconciliation。

退出条件：Shadow Candidate 能可靠转成一个外部 Agent Run，重试不重复激活。

### 第 7 周：Approval

- Tool Attempt；
- Authorization PDP；
- Web Approval；
- one-time Permit；
- adapter conformance；
- attack tests。

退出条件：敏感 Tool Attempt 无 Permit、Permit 过期、参数变化和重复消费全部被拒绝。

### 第 8 周：Outcome & Canary

- Outcome verification；
- 原生消息与 fallback 通知去重；
- 用户反馈；
- retention/delete；
- notify-only canary；
- metrics dashboard。

退出条件：一个真实对话承诺完成端到端闭环，并有完整时间线。

## 11. MVP 验收用例

### AC-01：无 Prompt 主动 Wake

给定 Omi finalized transcript 包含明确承诺，且不在冷却或静默限制内；系统生成 <code>WAKE_AGENT</code> 和 Task Contract，无需用户再次输入 Prompt。

### AC-02：模糊内容不打扰

给定“有空也许看看报价”之类弱意向；系统在 Shadow/Live 均不得自动唤醒执行 Agent。

### AC-03：重复事件幂等

同一 Provider Event 重放十次，只生成一个 Cue Event、一个 Episode 更新和至多一个 Wake。

### AC-04：主动补充观察受限

Decision 请求 <code>conversation.recent_segments</code> 时，只能访问允许的会话窗口；请求未注册 capability 必须拒绝。

### AC-05：执行属于 Agent

Task Contract 发给 Runtime 后，具体工具选择由 Agent 决定；WakeOnCue 核心没有直接 MCP Tool Loop。

### AC-06：敏感操作确认

Agent 尝试向张三发送文件时必须暂停。没有批准、Permit 过期、收件人变化或附件变化均不能执行。

### AC-07：Runtime 不支持拦截

Adapter conformance 表明 Runtime 没有 pre-tool interception 时，只读能力可以开启，所有写能力配置失败并给出明确原因。

### AC-08：结果未知不重复

外部 Runtime 超时但可能已执行时，Task 进入 <code>UNKNOWN</code>/<code>RECONCILING</code>，不得自动重发消息。

### AC-09：通知不重复

Runtime 原生渠道已经成功通知时，fallback 不发送相同成功通知；审批超时或高风险失败仍可升级。

### AC-10：证据回溯

从最终通知可以回到 Task、Decision、Episode 和原始 Cue Evidence Ref，并看到策略、模型、批准人、Tool Result 与验证等级。

## 12. 发布门槛

### Shadow → Notify

- 至少 7 天真实 Shadow 数据；
- 明确承诺 Precision 达标；
- 用户能查看并纠正误判；
- 每个 Candidate 有证据引用和原因码；
- 没有隐私越界观察。

### Notify → Wake

- 用户按 Cue Type 显式开启；
- Runtime Adapter 通过幂等与状态回调测试；
- 写能力必须通过 PEP conformance；
- Tool Attempt/Permit 攻击测试全部通过；
- 用户能一键暂停 Source 和撤销 Runtime。

### MVP Done

只有同时满足以下条件才算完成：

1. Omi 和通用 Webhook 都可以稳定产生 Cue；
2. Shadow、Notify、Wake 三种模式可配置；
3. 明确对话承诺可以无 Prompt 唤醒真实外部 Runtime；
4. 敏感写操作得到具体参数的一次性确认；
5. 结果被回收、验证、去重通知；
6. 整条链路可回放、可解释、可删除；
7. 重复副作用和授权绕过测试均为零。
