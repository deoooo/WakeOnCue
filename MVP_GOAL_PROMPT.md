# WakeOnCue MVP Goal Prompt

下面整段可以直接粘贴到 Codex。它把“工程 MVP 完成”与“需要真实用户数据的 7 天上线观察”分开：前者是本 Goal 的停止条件，后者仍是产品从 Shadow 升级到 Notify/Wake 的硬门槛，不能为了完成 Goal 而绕过。

~~~text
/goal 在 /path/to/WakeOnCue 中实现并交付 WakeOnCue 的完整工程 MVP。持续工作，不要在规划、脚手架、单元测试或局部演示后停止；只有下面“唯一停止条件”全部有可复现证据时才结束 Goal。

## 一、唯一目标

把当前只有架构与 MVP 设计的私有仓库，变成一个可以从干净 clone 启动、测试和演示的真实系统，完整证明这条纵向链路：

现实事件（Omi finalized transcript 或签名 Webhook）
→ 统一 Cue Event
→ 幂等入库、Episode 合并和 World State 投影
→ IGNORE / OBSERVE_MORE / WAKE_AGENT 决策
→ 无需用户再次输入 Prompt，主动唤醒真实外部 Agent Runtime
→ Agent 自己规划并形成具体 Tool Attempt
→ 敏感写操作在执行边界被强制暂停
→ 用户看到精确参数并一次性批准或拒绝
→ Agent 持 Permit 执行一次
→ Outcome 回收、验证、通知去重
→ 用户可从同一条时间线回溯证据、决策、授权和结果
→ Replay 不产生重复 Wake 或重复外部副作用。

WakeOnCue 的产品主叙事是 Cue → Decide → Wake。链路追踪是可信基础，但不是替代主动触发价值的主产品。

## 二、开始前必须读取并遵守

先完整阅读：

- README.md
- docs/architecture.md
- docs/mvp.md
- docs/architecture.html
- 仓库中的 AGENTS.md、现有配置和 CI 文件（如果存在）

以 docs/mvp.md 的 MVP Done 和 AC-01～AC-10 为产品验收合同，以 docs/architecture.md 第 14 节为不可破坏的架构约束。如果实现事实与文档冲突，先记录冲突，做最小且有理由的文档修订，再继续实现；不能静默改变产品边界或降低验收标准。

建立并持续更新 docs/implementation-status.md。每个 checkpoint 只记录：已实现内容、实际运行的验证、证据位置、剩余工作、已知风险或真正 blocker。不要把计划写成完成证据。

## 三、实现边界

### 必须实现

1. Source 与契约
   - 版本化 Cue Event、Attention Decision、Task Contract、Tool Attempt、Permit、Outcome 和 Notification Schema。
   - 通用 HMAC 签名 Webhook，包含时间窗、防重放、Schema 校验、Idempotency-Key 和隔离错误记录。
   - Omi finalized transcript/conversation Adapter；供应商类型不得泄漏到核心领域模型。
   - Source SDK、Runtime SDK、Notification SDK 及各自 conformance tests。
   - Omi 实机凭证或设备不可用时，必须使用版本化、脱敏的真实格式 fixture 完成契约验证，并明确标注“fixture 验证，不是线上实机证明”。用户设备和私有凭证不属于工程 MVP 的停止条件。

2. Cue Core
   - Append-only Event Log；事实、派发、Projection 分离。
   - Episode Builder 的 dedup、debounce、merge；跨 Source correlation；撤回和截止时间变化。
   - 简单实体、承诺、时间和结构化异常提取。
   - 可由事件重建的 World State、Task View 和 Timeline Projection。
   - Replay API、CLI、golden corpus；相同版本对同一事件流产生确定性结果。
   - Transactional outbox、consumer inbox/delivery ledger、幂等重试和 UNKNOWN reconciliation。

3. Attention 与主动触发
   - Hard Gate、确定性信号、novelty、cooldown、quiet hours、每日预算和 Wake Gate。
   - provider-neutral Structured Judge 接口，严格结构化输出、预算、超时和安全降级；测试不能依赖真实付费模型。
   - IGNORE、OBSERVE_MORE、WAKE_AGENT 三种结果。
   - Observation 只能调用注册的只读 capability，必须有目的、数据范围、预算、TTL 和保留期；Attention 本身不得形成任意 Tool Loop。
   - Shadow、Notify、Wake 按 Source + Cue Type 配置；新 Source 默认 Shadow。
   - 完整 reason codes、evidence refs、strategy/model version；不得存储或展示内部 Chain-of-Thought。

4. Wake 与真实 Agent Runtime
   - Task Contract 只传目标、约束、成功条件、证据引用和初始 capability scope，不替 Agent 规划工具步骤。
   - 通用 Runtime Webhook Adapter。
   - 首个官方 Runtime 选择 OpenClaw；实现前核对当时版本的官方文档和代码，使用其受支持的 hook/plugin/channel/HTTP 接口，不假设未验证的拦截能力。
   - 最终 E2E 必须启动并唤醒一个真实 OpenClaw 进程或其官方可运行形态，不能用 fake runtime 代替最终证明。可用 fake runtime 做低层测试。
   - Runtime activation、callback/poll、cancel、timeout、幂等查询和 RUN_ACCEPTED/RUNNING/WAITING_APPROVAL/SUCCEEDED/FAILED/CANCELLED/UNKNOWN 生命周期。
   - 如果所用 OpenClaw 版本没有可靠 pre-tool interception，则通过只暴露 WakeOnCue Tool Gateway/PEP 包装后的工具形成强制执行边界；无法经过 PEP 的写工具必须禁用。OpenClaw 自带审批只能作为第二道门。
   - 架构保持 Runtime-neutral，使后续 Pi Agent Adapter 只需实现同一 SDK；Pi Adapter 本身不是 MVP 必做项。

5. Authorization 与执行边界
   - 具体工具选择和执行循环属于 Agent Runtime；WakeOnCue 不实现 Planner，也不直接决定该调用哪个 MCP/tool。
   - Runtime Guard/Tool Gateway 在真实调用前提交 Tool Attempt，由集中 PDP 返回 ALLOW、APPROVE_ONCE 或 DENY。
   - 默认允许范围仅限受约束只读查询、草稿/摘要/计划和 WakeOnCue 自有通知模板。
   - 外发消息、邮件、文件以及修改日历、任务或业务记录必须逐次确认。
   - 支付、购买、删除、门锁/设备控制和未知工具在 MVP 中拒绝。
   - Web 审批页显示 Agent、目标、工具、目标对象、精确参数/数据摘要、可逆性、费用和超时，只提供批准一次与拒绝。
   - Permit 绑定 subject/runtime/task/attempt/tool/canonical arguments digest/短 TTL，原子消费一次；参数、目标或附件变化必须重新批准。
   - LLM 输出、Task Contract、Agent 配置和 Runtime 自带批准都不能生成或替代 Permit。

6. Outcome、通知与产品界面
   - Outcome 分 reported、tool-confirmed、externally-verified；“Agent 说完成”不能自动成为已验证。
   - Runtime 原生消息回执和一个 fallback Notification Adapter，按 task/outcome/channel 去重；原生渠道成功后不重复发送相同 fallback 成功通知。
   - 审批、高风险失败、UNKNOWN、已验证完成和普通摘要分别治理；quiet hours、预算和升级策略可验证。
   - React/Vite Console 至少包含：Source/Cue Type 模式配置、Cue/Episode 列表、Decision 解释、Task 时间线、审批卡、结果/通知状态、反馈、Replay 发起和删除入口。
   - 从通知或 Task 可回到 cueEventId → episodeId → decisionId → taskId → runtimeRunId → toolAttemptId → permitId → outcomeId → notificationId 的证据链。

7. 安全、隐私与运维
   - 原始音视频默认不复制；最小化保存必要文本和 evidence refs。
   - 凭证只放 Secret Store/环境变量；提交 .env.example，禁止提交真实密钥、个人数据和带隐私的原始转写。
   - 敏感字段静态加密或明确的可替换加密边界；结构化日志和 UI 默认脱敏。
   - Retention、tombstone、payload/projection 删除、授权撤销、在途任务处理、备份与恢复。
   - OpenTelemetry trace 与业务关联 ID 并存；日志采样不得破坏业务审计。
   - 健康检查、优雅停机、可诊断错误、重试上限和本地 metrics。

## 四、建议技术基线

除非实测发现兼容性阻碍，采用以下基线，避免在 Goal 中反复重选技术：

- Node.js 24 LTS、TypeScript strict、pnpm workspace；
- Fastify + TypeBox/AJV，Schema 作为公开契约的唯一事实来源；
- SQLite + 显式 SQL migration + repository abstraction；先做可靠单机模块化服务，不为 MVP 引入 Kafka；
- React + Vite；
- OpenTelemetry；
- Vitest + API integration tests + Playwright E2E；
- 容器化依赖和本地运行使用 Docker Compose；同时提供不依赖容器的最小开发路径（若本机可用）；
- 使用结构化模型 provider interface 和测试用 deterministic provider，不把任一 LLM 厂商写进领域层。

推荐目录遵循 docs/architecture.md 的 apps/ 与 packages/ 边界。可以为本机 Agent 增加 apps/connector：它只能通过 outbound HTTPS/WSS 连接控制面，持有短期、最小范围的运行时凭证，并带 SQLite spool；不要因此把核心拆成过多网络微服务。MVP 默认可在单机/Compose 完整运行，未来再把控制面迁移 PostgreSQL。

依赖和第三方 API 可能变化。涉及 OpenClaw、Omi、Node 或库行为时，优先检查当前官方文档、实际版本和源码，记录已验证版本，不依靠陈旧记忆。

## 五、按可运行 checkpoint 推进

保持一个当前 checkpoint，完成后立即运行对应证明，再进入下一个。合理顺序是：

1. Bootstrap：workspace、配置、Schema、migration、CI、最小 API/worker/console 可启动。
2. Replay-first：Event Log、Webhook、projection、dedup/outbox、Replay CLI 和 golden tests。
3. Conversation Cue：Omi Adapter、Episode、提取、Attention、Shadow/Notify/Wake、时间线。
4. Agent Wake：Task Contract、Runtime SDK/Webhook、真实 OpenClaw activation、状态回收和 UNKNOWN。
5. Approval：Tool Attempt、PDP、Web approval、Permit、PEP/Tool Gateway、attack tests。
6. Outcome：结果验证、原生/fallback 通知去重、反馈、retention/delete。
7. Full-story：从事件到真实 Agent、受控写工具、审批、结果、通知、时间线和 Replay 的完整 E2E。
8. Release audit：干净 clone、全量测试、性能/安全门槛、文档、证据矩阵、Draft PR。

每个 checkpoint 建立小而可审计的提交并推送。若当前在 main 且工作树干净，创建 codex/mvp 分支；若 Codex 已为任务创建分支，则继续当前任务分支。创建或持续更新 Draft PR，但不要自行合并，不要公开仓库，不要部署到公开生产环境。

## 六、必须通过的验证

仓库必须提供稳定的一键命令；具体脚本名可在 bootstrap 时确定，但至少覆盖并在 CI 与本地实际运行：

- install/clean bootstrap；
- format check、lint、typecheck；
- unit tests；
- Schema/SDK/Adapter conformance tests；
- SQLite migration 和 repository integration tests；
- replay/golden evaluation；
- authorization attack suite；
- API/runtime/notification integration tests；
- Playwright Console E2E；
- real-openclaw E2E；
- full-story E2E；
- production build；
- secret/credential scan；
- clean-clone smoke test。

必须把 docs/mvp.md 的 AC-01～AC-10 做成自动化测试或明确的半自动验证脚本，并生成 docs/evidence/mvp-acceptance.md，逐项列出：用例、命令、结果、日志/trace/截图或 artifact 路径、对应 commit。不能只写“已完成”。

Replay corpus 至少覆盖：明确承诺、模糊愿望、玩笑/假设、撤回、重复、说话人混淆、截止时间变化、quiet hours、跨源重复、Prompt Injection，以及 Runtime 成功/失败/超时/UNKNOWN。

必须达到：

- 重复外部副作用 = 0；
- 未授权敏感 Tool Attempt = 0；
- 参数 digest 不一致仍可执行 = 0；
- Permit 重复消费成功 = 0；
- 同版本 Replay 决策一致率 = 100%；
- Shadow 证据链完整率 = 100%；
- 离线明确承诺 Precision ≥ 90%，Recall ≥ 75%；
- 本地基准 p95 规则路径 ≤ 500 ms，含 Judge 路径 ≤ 5 s，记录硬件和测试配置；
- 所有外部副作用都存在 idempotency/delivery record；
- 所有 AC-01～AC-10 都有证据。

“每用户每日误唤醒 ≤ 0.2”和 Shadow → Notify 的 7 天真实数据仍是上线门槛。把门槛实现为产品内可计算、可查看、不可绕过的 gate，但没有用户真实数据时不虚构 7 天结果，也不把它作为工程 MVP 的自主停止条件。生产 Live Wake 默认保持关闭。

## 七、唯一停止条件

只有同时满足以下全部条件，才能把 Goal 标记为完成：

1. 从干净 clone 按 README 的命令可以安装、迁移、启动 API/worker/console 和必要 connector；
2. 通用签名 Webhook 与 Omi Adapter 均能稳定生成统一 Cue，重复输入不会重复形成事件或 Wake；
3. Shadow、Notify、Wake 可按 Source + Cue Type 配置，默认与升级 gate 正确；
4. 明确对话承诺能在无新 Prompt 的情况下唤醒真实 OpenClaw，Task Contract 和状态回流可见；
5. OpenClaw 中具体工具选择由 Agent 完成；受控敏感写工具在真实执行边界被 PEP 暂停；
6. 无批准、过期 Permit、参数变化、目标变化和重复消费全部执行失败；精确批准后只执行一次；
7. Outcome 被回收并分级验证，原生/fallback 通知去重，最终结果回到同一时间线；
8. 完整链路可回放、解释、删除，UNKNOWN 不会导致盲目重试；
9. AC-01～AC-10、攻击测试、全量质量命令、production build、real-openclaw E2E、full-story E2E 和 clean-clone smoke 全部通过；
10. docs/evidence/mvp-acceptance.md 包含可复现证据，docs/implementation-status.md 没有未解决的 MVP 项；
11. README、架构、API、运行、OpenClaw 接入、审批安全、备份恢复和故障排查文档与实现一致；
12. Git 工作树干净，所有任务改动已提交并推送到私有远端，Draft PR 指向最新 commit，未提交秘密或个人数据。

最终报告必须给出：完成摘要、运行方式、技术架构、测试命令与实际结果、AC-01～AC-10 证据矩阵、真实 OpenClaw E2E 证据、仍属于生产 canary 而非工程 MVP 的事项、分支/commit/PR。不要把 fixture/scripted smoke 描述成生产能力证明。

## 八、自主工作与暂停规则

- 先制定执行计划，然后立即实现；不要在给出计划后等待确认。
- 在安全、可逆、仓库范围内做合理假设，优先用代码、测试、日志和运行结果消除不确定性。
- 遇到测试失败、依赖冲突、端口问题或实现困难时自行诊断、修复并重试，不要因为“工作很多”而停止。
- 只在确实需要用户提供私有凭证/设备、授权付费服务、执行真实对外敏感操作、公开部署、改变不可破坏的产品边界，或同一外部 blocker 反复确认仍无法绕过时暂停并明确提问。
- 等待用户输入前，先完成所有不依赖该输入的工作，并记录 blocker、已尝试证据和恢复后的下一命令。
- Omi 私有凭证缺失时继续 fixture/conformance；真实对外消息不得用于测试，使用受控本地 test receiver/tool。OpenClaw 本地真实进程仍是停止条件。
- 不得通过关闭安全检查、放宽断言、删除失败样本、使用宽泛永久授权、把 fake runtime 当最终 E2E，或把 UNKNOWN 当失败自动重试来“完成”目标。
- 不扩展到自研 ASR/CV/硬件、支付/购买/删除/设备控制、多 Agent 编排、Pi 官方 Adapter 或生产多租户，除非它是完成上述纵向链路不可避免的最小工作。
- 跨 turn 或上下文压缩后，从 docs/implementation-status.md、Git 历史和实际测试状态自然继续，不从头重做，也不因单次 turn 结束而宣告完成。
~~~

## 为什么这份 Prompt 能长跑

它将 Goal 压缩为一个纵向结果，把产品边界、证明命令、暂停条件和唯一停止条件一起固化。执行过程中可以调整实现细节，但不能把“代码写了”“fixture 通过了”或“Agent 报告成功”替代真正的端到端证据。
