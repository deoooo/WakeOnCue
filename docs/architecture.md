# WakeOnCue 系统架构

状态：Draft 0.1  
更新时间：2026-08-12

## 1. 架构结论

WakeOnCue 是位于“现实世界感知”和“Agent Runtime”之间的主动唤醒层：

> 它判断某个现实 Cue 是否值得补充观察、是否值得唤醒 Agent，以及这次唤醒可以携带什么权限；它不替 Agent 规划和执行任务。

主路径只有三种决策：

~~~text
IGNORE | OBSERVE_MORE | WAKE_AGENT
~~~

其中：

- <code>IGNORE</code>：事件不值得打扰或已经处理过；
- <code>OBSERVE_MORE</code>：当前证据不足，只请求被允许的有限观察；
- <code>WAKE_AGENT</code>：形成 Task Contract，唤醒指定 Runtime；
- Agent 形成具体 Tool Attempt 后，敏感操作才进入授权与人工确认；
- 执行结果和用户反馈重新进入 Cue 流。

链路追踪、证据引用和审计是所有模块共享的基础设施，但不是产品的第一叙事。产品第一叙事是：**无需新的 Prompt，现实事件在正确时机主动唤醒 Agent。**

## 2. 系统上下文

~~~mermaid
flowchart LR
    World["现实世界<br/>对话 / 设备 / 应用 / 环境"] --> Sources["Perception Providers<br/>Omi / ASR / CV / HA / Webhook"]
    Sources --> WOC["WakeOnCue<br/>Cue → Decide → Wake"]
    WOC --> Runtime["Agent Runtime<br/>OpenClaw / Pi Agent / Others"]
    Runtime --> Tools["MCP / API / Local Tools"]
    Runtime --> WOC
    WOC --> User["用户<br/>确认 / 通知 / 反馈"]
    User --> WOC
~~~

### 边界

WakeOnCue 负责：

- 统一接收异构现实事件；
- Cue 归一化、关联、合并和短期世界状态；
- 主动补充观察；
- 低成本 Attention Cascade；
- Wake Policy、Runtime 路由和 Task Contract；
- 敏感 Tool Attempt 的集中授权决策；
- 运行结果回收、验证、通知治理和时间线；
- 事件到结果的关联标识和可回放记录。

WakeOnCue 不负责：

- 自研通用 ASR、CV 或可穿戴硬件平台；
- 通用 Agent Planner、Tool Loop、Memory 或 Skill 市场；
- 代替 Agent 调用任意 MCP/API/本机工具；
- 未经许可持续扩大感知范围；
- 用自由文本推理过程充当审计证据。

## 3. 逻辑架构

~~~mermaid
flowchart TB
    subgraph Perception["可替换感知供应商"]
      Omi["Omi transcript"]
      Hook["Generic webhook"]
      HA["Home Assistant"]
      More["Future ASR / CV / App"]
    end

    subgraph CuePlane["WakeOnCue · Cue Plane"]
      Ingest["Ingress Gateway<br/>auth / schema / privacy / idempotency"]
      EventLog["Cue Event Log<br/>append-only / replay"]
      Understand["Cue Understanding<br/>perceptor / entity / episode"]
      State["World State Projection<br/>current state / recent episode"]
      Attention["Attention Cascade<br/>IGNORE / OBSERVE_MORE / WAKE_AGENT"]
      Observe["Observation Broker<br/>bounded capability request"]
      WakePolicy["Wake Policy<br/>budget / runtime / pre-approval"]
      Contract["Task Contract + Wake Outbox"]
    end

    subgraph RuntimePlane["Agent Execution Plane"]
      Adapter["Runtime Adapter"]
      Runtime["OpenClaw / Pi Agent / Other"]
      Plan["Agent planning + tool selection"]
      PEP["Runtime Guard / PEP"]
      Tools["MCP / API / Local Tools"]
    end

    subgraph Safety["WakeOnCue · Authorization"]
      PDP["Authorization PDP"]
      Approval["Human Approval"]
      Permit["One-time Permit"]
    end

    subgraph CloseLoop["Outcome Loop"]
      Outcome["Outcome Reconciliation"]
      Verify["Result Verification"]
      Notify["Native reply + fallback notification"]
      Timeline["Cue / Task Timeline"]
    end

    Omi & Hook & HA & More --> Ingest
    Ingest --> EventLog --> Understand --> State --> Attention
    Attention -->|OBSERVE_MORE| Observe
    Observe --> EventLog
    Attention -->|WAKE_AGENT| WakePolicy --> Contract --> Adapter --> Runtime --> Plan --> PEP
    Attention -->|IGNORE| Timeline
    PEP -->|safe| Tools
    PEP -->|sensitive attempt| PDP --> Approval --> Permit --> PEP
    Tools --> Outcome --> Verify --> Notify --> Timeline
    Runtime --> Outcome
    Timeline --> EventLog
~~~

## 4. 组件职责与替换接口

| 组件 | 单一职责 | 插件接口 | 禁止承担 |
|---|---|---|---|
| Source Adapter | 将供应商事件转换为 Cue Envelope | <code>ingest(raw) → CueEvent[]</code> | 判断是否唤醒、直接执行任务 |
| Cue Event Log | 保存事实、引用和状态变化 | <code>append</code> / <code>read</code> / <code>replay</code> | 作为实时派发器或 Prompt |
| Perceptor | 从 Cue 提取实体、意图候选和事实 | <code>perceive(event, context)</code> | 产生外部副作用 |
| Correlator | 去重、合并 Episode、关联跨源事件 | <code>correlate(fact)</code> | 调用 Agent 工具 |
| World State Projector | 从事件重建当前可查询状态 | <code>project(events)</code> | 保存不可回放的隐藏状态 |
| Attention Strategy | 决定忽略、补充观察或唤醒 | <code>decide(snapshot)</code> | 直接调用 MCP/Tools |
| Observation Provider | 执行白名单内的有限感知请求 | <code>observe(request)</code> | 任意探索或写操作 |
| Wake Policy | 决定是否唤醒、唤醒谁、预算和初始能力 | <code>authorizeWake(candidate)</code> | 规划具体工具步骤 |
| Runtime Adapter | 翻译 Task Contract 和 Runtime 生命周期 | <code>activate</code> / <code>observe</code> / <code>cancel</code> | 实现另一套 Agent Runtime |
| Authorization PDP | 对具体 Tool Attempt 作授权决策 | <code>evaluate(attempt)</code> | 猜测 Agent 后续所有步骤 |
| Notification Adapter | 去重后投递审批、失败或结果 | <code>deliver(notification)</code> | 成为任意消息发送工具 |

所有接口都必须：

- 有版本字段；
- 使用稳定 ID 和幂等键；
- 只传结构化对象与证据引用；
- 显式声明数据敏感等级、保留时间和调用预算；
- 支持超时、取消和未知结果；
- 不把供应商 SDK 类型泄漏进核心领域模型。

## 5. 核心契约

### 5.1 Cue Event

~~~json
{
  "specVersion": "wakeoncue.event/v1",
  "eventId": "evt_01J...",
  "type": "conversation.commitment.detected",
  "source": {
    "adapter": "omi",
    "providerRef": "device_123"
  },
  "subject": "user_abc",
  "occurredAt": "2026-08-12T12:01:22+08:00",
  "receivedAt": "2026-08-12T12:01:24+08:00",
  "correlationId": "conversation_456",
  "confidence": 0.93,
  "data": {
    "speaker": "user",
    "commitment": "周五之前把报价发送给张三"
  },
  "evidenceRefs": [
    {
      "uri": "omi://conversation/456#segment=9",
      "mediaType": "text/plain",
      "classification": "private"
    }
  ],
  "privacy": {
    "purpose": ["attention", "task-activation"],
    "retention": "P7D"
  },
  "idempotencyKey": "omi:conversation_456:segment_9:v1"
}
~~~

原则：

- 原始音视频优先留在供应商或用户设备，核心默认保存引用；
- <code>occurredAt</code> 和 <code>receivedAt</code> 分开，允许延迟事件；
- 低置信度不是自动丢弃的唯一理由，可以进入 <code>OBSERVE_MORE</code>；
- 删除或到期通过 tombstone 事件表达，投影随之清除。

### 5.2 Attention Decision

~~~json
{
  "decisionId": "dec_01J...",
  "episodeId": "ep_01J...",
  "decision": "WAKE_AGENT",
  "reasonCodes": [
    "EXPLICIT_COMMITMENT",
    "DEADLINE_PRESENT",
    "NOT_DUPLICATE"
  ],
  "scores": {
    "relevance": 0.94,
    "urgency": 0.72,
    "novelty": 0.88,
    "userCost": 0.24
  },
  "evidenceRefs": ["evt_01J..."],
  "strategyVersion": "attention-v1",
  "modelRef": "judge-model@version",
  "cooldownKey": "commitment:quote:recipient_zhangsan",
  "expiresAt": "2026-08-12T12:11:24+08:00"
}
~~~

不保存自由文本 Chain-of-Thought。可审计内容是输入摘要、结构化评分、原因码、模型版本、策略版本和证据引用。

### 5.3 Task Contract

~~~json
{
  "contractVersion": "wakeoncue.task/v1",
  "taskId": "task_01J...",
  "goal": "在周五之前向张三发送最终报价",
  "successCriteria": [
    "报价内容经用户确认",
    "目标收件人唯一确定",
    "发送渠道返回可验证回执"
  ],
  "constraints": [
    "发送前必须人工确认",
    "不得向其他联系人发送"
  ],
  "contextRefs": ["evt_01J...", "ep_01J..."],
  "deadline": "2026-08-14T17:00:00+08:00",
  "runtime": {
    "adapter": "openclaw",
    "profile": "personal-assistant"
  },
  "capabilityScope": [
    "contacts.read",
    "draft.create"
  ],
  "approvalRequiredFor": [
    "message.send",
    "file.share"
  ],
  "idempotencyKey": "wake:commitment:quote:recipient_zhangsan:2026-08-14"
}
~~~

Task Contract 传递目标和约束，不预先规定 Agent 的完整工具计划。

### 5.4 Tool Attempt 与 Permit

Agent 形成具体操作后，Runtime Guard 才提交授权：

~~~json
{
  "attemptId": "attempt_01J...",
  "taskId": "task_01J...",
  "runtimeRunId": "run_external_123",
  "tool": "message.send",
  "argumentsDigest": "sha256:...",
  "displaySummary": "向联系人张三发送《最终报价.pdf》",
  "risk": {
    "sideEffect": "external-write",
    "reversible": false,
    "dataClassification": "confidential",
    "destination": "contact:zhangsan"
  }
}
~~~

授权返回：

~~~json
{
  "decision": "APPROVE_ONCE",
  "permitId": "permit_01J...",
  "attemptId": "attempt_01J...",
  "argumentsDigest": "sha256:...",
  "expiresAt": "2026-08-12T12:06:00+08:00"
}
~~~

Permit 必须绑定 Runtime、Task、Attempt、参数摘要和短 TTL，使用一次后立即失效。参数改变必须重新确认。

## 6. 主动触发决策

Attention Cascade 按成本从低到高执行：

1. **Hard Gate**：Schema、来源授权、TTL、隐私目的、最小置信度；
2. **Episode Builder**：幂等、去重、debounce、跨源合并；
3. **Cheap Signals**：明确承诺、截止时间、异常状态、用户相关性；
4. **Novelty & Cost**：近期是否已经处理、当前打扰预算、静默时段；
5. **OBSERVE_MORE**：仅请求缺失且被授权的观察；
6. **Judge**：结构化模型判断是否值得唤醒；
7. **Wake Gate**：焦点验证、语义重复抑制、冷却与 Runtime 选择；
8. **Outbox**：持久化 Task Contract 后再异步激活 Runtime。

任何阶段都可以返回 <code>IGNORE</code>。只有少数候选进入昂贵 Judge。

### OBSERVE_MORE 的边界

Observation Broker 不是另一个 Agent。它只接受已注册能力：

~~~text
conversation.recent_segments
entity.current_state
camera.snapshot
calendar.window
~~~

每个请求必须指定：

- capability 与目标 Source；
- 目的、最大成本、TTL；
- 最小所需数据范围；
- 是否需要用户预授权；
- 结果的保留时间。

## 7. 执行与授权边界

### 7.1 为什么授权不能只下放到 Agent 配置

Agent 配置适合声明“有哪些工具”，但不能成为唯一安全边界：

- 不同 Runtime 的权限语义不同；
- Agent 可能被提示注入或错误规划；
- 预先授权整个工具过宽，真正风险取决于具体参数和目标；
- 用户需要在一个产品面查看和撤销授权。

因此采用 PDP / PEP：

- **PDP**：WakeOnCue 集中判断策略；
- **PEP**：OpenClaw 插件、Pi Extension 或 Runtime Adapter 在工具调用前强制拦截；
- **Runtime**：负责形成计划和 Tool Attempt；
- **用户**：对具体敏感 Attempt 作一次性确认。

如果 Runtime 没有可靠的调用前拦截点，则该 Adapter 只能运行只读工具，不能宣称支持敏感执行。

### 7.2 默认风险策略

| 操作类别 | 默认策略 |
|---|---|
| 本地只读查询 | 可自动允许，受数据范围限制 |
| 生成草稿、摘要、计划 | 可自动允许，不对外发布 |
| 通知当前用户 | 可自动允许，受打扰预算和静默时段限制 |
| 外发消息、邮件、文件 | 每次确认 |
| 修改日历、任务、业务记录 | 每次确认；成熟后可配置窄范围授权 |
| 支付、购买、删除、设备控制 | MVP 禁止 |
| 未知工具或参数无法解释 | 拒绝 |

OpenClaw、Pi Agent 或其他 Runtime 自己的审批能力可作为第二道门，但 WakeOnCue 不能假设宿主一定会阻拦。安全保证必须由 Adapter 能力声明和 PEP 验证决定。

## 8. Runtime 与通知兼容

### Runtime Adapter

MVP 窄接口：

~~~text
activate(taskContract, policyToken) -> runtimeRunId
observe(runtimeRunId) -> RuntimeRunState
cancel(runtimeRunId, reason) -> CancelResult
~~~

Runtime 通过 Callback 或轮询回传：

~~~text
RUN_ACCEPTED
RUNNING
WAITING_APPROVAL
SUCCEEDED
FAILED
CANCELLED
UNKNOWN
~~~

<code>UNKNOWN</code> 是一等状态。外部执行结果不确定时禁止盲目重试。

### 通知策略

优先使用 Runtime 原生渠道保持对话连续性，例如 OpenClaw 已绑定的聊天渠道。WakeOnCue 负责：

- 将 <code>taskId</code>、<code>runtimeRunId</code> 和原生消息回执关联；
- 对相同结果做去重；
- 原渠道不可用、审批超时或高风险失败时走 fallback；
- 通知 Deep Link 打开同一条 Cue / Task 时间线；
- 将 opened、acknowledged、dismissed 作为反馈事件。

通知不是任意工具执行。WakeOnCue 只允许自己的审批、失败、完成和摘要模板。

## 9. 状态、可靠性和回放

### 9.1 事实与派发分离

- Event Log：事实来源，可持久、可回放；
- Event Bus：进程内或远端派发，可丢失后重建；
- Outbox：保证 Wake、通知等副作用在提交后最终派发；
- Inbox / Delivery Ledger：保证消费者和外部投递幂等；
- Projection：World State、Task View、Timeline 均可从日志重建。

MVP 使用 SQLite 的 append-only 表和事务 Outbox。接口保持 transport-neutral，达到真实吞吐或可用性瓶颈后再迁移 PostgreSQL、队列或 A2A Broker。

### 9.2 Task 状态机

~~~mermaid
stateDiagram-v2
    [*] --> CANDIDATE
    CANDIDATE --> IGNORED
    CANDIDATE --> OBSERVING
    OBSERVING --> CANDIDATE
    CANDIDATE --> PROPOSED
    PROPOSED --> ACTIVATING
    ACTIVATING --> RUNNING
    ACTIVATING --> UNKNOWN
    RUNNING --> WAITING_APPROVAL
    WAITING_APPROVAL --> RUNNING
    WAITING_APPROVAL --> REJECTED
    RUNNING --> SUCCEEDED
    RUNNING --> FAILED
    RUNNING --> UNKNOWN
    SUCCEEDED --> VERIFIED
    SUCCEEDED --> UNVERIFIED
    VERIFIED --> NOTIFIED
    FAILED --> NOTIFIED
    UNKNOWN --> RECONCILING
    RECONCILING --> RUNNING
    RECONCILING --> SUCCEEDED
    RECONCILING --> FAILED
~~~

## 10. 证据与可观测性

每一条业务链路使用以下稳定关联：

~~~text
cueEventId
  → episodeId
  → decisionId
  → taskId
  → runtimeRunId
  → toolAttemptId
  → permitId
  → outcomeId
  → notificationId
~~~

需要同时保留两类记录：

1. **业务证据链**：来源、事件、原因码、授权、结果与用户反馈；
2. **运行观测链**：OpenTelemetry trace、span、latency、error、cost。

两者通过稳定业务 ID 关联，但不能互相替代。日志采样不能破坏业务审计；业务证据保留也不能意味着永久保存原始音视频。

### 回溯时必须回答

- 哪个现实 Cue 触发了判断？
- 使用了哪些原始证据或供应商引用？
- 为什么选择忽略、补充观察或唤醒？
- 哪个策略、模型和版本参与了决策？
- 唤醒了哪个 Agent Runtime，给了什么范围？
- Agent 计划了什么具体 Tool Attempt？
- 谁在什么时候批准了哪些精确参数？
- 工具结果是 Agent 报告、工具确认还是外部验证？
- 用户是否收到、打开、接受或驳回？

## 11. 部署形态

### MVP：单机模块化服务

~~~text
wakeoncue-api
wakeoncue-worker
wakeoncue-console
SQLite + local artifact refs
Omi adapter + Webhook adapter
One runtime adapter
One notification adapter
~~~

推荐参考技术栈：

- TypeScript + Node.js 22；
- Fastify + JSON Schema/Zod；
- SQLite + repository abstraction，后续切 PostgreSQL；
- DB-backed queue/outbox，不先引入 Kafka；
- React/Vite 的轻量任务时间线；
- OpenTelemetry；
- Vitest + replay fixtures。

技术栈是实现建议，不进入领域接口。

### 规模化演进

只有出现明确瓶颈后才拆分：

1. 独立 Source Gateway；
2. PostgreSQL 与独立 Worker；
3. 远端 Event Transport；
4. 多租户 Policy Service；
5. 企业 Agent Mesh / A2A Adapter。

## 12. 与类似项目的差异

| 系统 | 主要解决的问题 | WakeOnCue 与其关系 |
|---|---|---|
| Omi | 可穿戴音频、转写、对话与 App/通知生态 | 作为感知来源；WakeOnCue 泛化到异构 Cue，并负责跨源 Wake 决策 |
| OwnPilot | 围绕任务、日历和记忆的个人 Agent 主动 Pulse | 借鉴 gate、cooldown 和 autonomy；WakeOnCue 不绑定封闭上下文，也不自己执行工具 |
| OpenClaw / Pi Agent | Agent 规划、工具调用和宿主渠道 | 作为 Runtime；WakeOnCue 提供无 Prompt 的主动入口与统一授权闭环 |
| MCP | 工具发现和调用协议 | 位于 Agent Runtime 与工具之间，不解决何时因现实事件启动 Agent |
| Agent Mesh / A2A | Agent 发现、路由与协作 | 是未来 Runtime/transport 选项，不解决原始 Cue 是否值得形成任务 |

WakeOnCue 的独立价值是：

> 开放现实事件契约 + 跨源短期世界状态 + 渐进观察 + 低打扰 Wake 决策 + 与外部 Runtime 解耦的授权/结果闭环。

## 13. 建议代码结构

~~~text
apps/
  api/                    # ingestion、query、approval API
  worker/                 # projector、attention、outbox
  console/                # Cue / Task 时间线
packages/
  contracts/              # event、decision、task、attempt schemas
  core/                   # 纯领域逻辑与状态机
  policy/                 # wake policy、authorization PDP
  storage/                # repository interfaces
  storage-sqlite/         # MVP adapter
  source-sdk/             # Source Adapter SDK
  source-webhook/
  source-omi/
  runtime-sdk/            # Runtime Adapter SDK
  runtime-webhook/
  runtime-openclaw/
  runtime-pi/
  notify-sdk/
  testing/                # replay fixtures 与 adapter conformance
docs/
  architecture.md
  architecture.html
  mvp.md
~~~

## 14. 不可破坏的架构约束

1. Source Adapter 不得决定 Wake；
2. Attention Engine 不得调用任意 MCP/Tools；
3. WakeOnCue 不得实现通用 Agent Planner；
4. 敏感 Tool Attempt 没有有效 Permit 不得执行；
5. 没有 pre-tool interception 的 Runtime Adapter 不得开放敏感工具；
6. 事件事实、派发和投影必须分离；
7. 所有外部副作用必须使用幂等键与 Delivery Record；
8. <code>UNKNOWN</code> 不得自动等同于失败并重试；
9. 原始隐私数据最小化保存，证据引用不等于复制内容；
10. 新 Source、Judge、Runtime、Policy 和 Notification 必须通过契约测试。
