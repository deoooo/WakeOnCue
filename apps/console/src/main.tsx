import { StrictMode, useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

import "./styles.css";

const apiUrl = import.meta.env.VITE_WAKEONCUE_API_URL ?? "http://127.0.0.1:4310";

interface CueEvent {
  eventId: string;
  type: string;
  occurredAt: string;
  source: { adapter: string; sourceId: string };
  evidenceRefs: Array<{ uri: string }>;
}

interface Episode {
  episodeId: string;
  subject: string;
  correlationId: string;
  eventIds: string[];
  types: string[];
  latestData: Record<string, unknown>;
  evidenceRefs: string[];
  lastOccurredAt: string;
  retracted: boolean;
}

interface DecisionEvaluation {
  decision: {
    decisionId: string;
    decision: "IGNORE" | "OBSERVE_MORE" | "WAKE_AGENT";
    reasonCodes: string[];
    evidenceRefs: string[];
    strategyVersion: string;
    modelRef?: string;
    expiresAt: string;
  };
  mode: "SHADOW" | "NOTIFY" | "WAKE";
  disposition: string;
  signals: { commitment?: string; deadline?: string; recipient?: string };
}

interface EpisodeListItem {
  episode: Episode;
  latestDecision?: DecisionEvaluation;
}

interface Timeline {
  episode: Episode;
  cues: CueEvent[];
  decisions: DecisionEvaluation[];
}

interface ApprovalRecord {
  attempt: {
    attemptId: string;
    taskId: string;
    agentRunId: string;
    tool: string;
    arguments: Record<string, unknown>;
    argumentsDigest: string;
    displaySummary: string;
    risk: {
      reversible: boolean;
      destination?: string;
      estimatedCost?: number;
      dataClassification: string;
    };
    createdAt: string;
  };
  status: string;
  reasonCode: string;
  task?: { contract: { goal: string } };
}

function timestamp(value: string): string {
  if (!value || Number.isNaN(new Date(value).getTime())) return "时间未知";
  return new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

async function readJson<T>(response: Response): Promise<T> {
  const body = (await response.json()) as T & { code?: string };
  if (!response.ok) throw new Error(body.code ?? `HTTP_${response.status}`);
  return body;
}

function App() {
  const [items, setItems] = useState<EpisodeListItem[]>([]);
  const [selected, setSelected] = useState<Timeline>();
  const [error, setError] = useState<string>();
  const [sourceId, setSourceId] = useState("omi-local");
  const [cueType, setCueType] = useState("conversation.finalized");
  const [mode, setMode] = useState<"SHADOW" | "NOTIFY" | "WAKE">("SHADOW");
  const [modeStatus, setModeStatus] = useState("新 Source 默认 Shadow；Live Wake 未开启");
  const [approvalToken, setApprovalToken] = useState(
    () => sessionStorage.getItem("wakeoncue.approvalToken") ?? "",
  );
  const [approvals, setApprovals] = useState<ApprovalRecord[]>([]);
  const [approvalStatus, setApprovalStatus] = useState(
    "输入本地 Approval Admin Token 后加载待审批项",
  );

  const refresh = useCallback(async () => {
    try {
      const body = await readJson<{ episodes: EpisodeListItem[] }>(
        await fetch(`${apiUrl}/v1/episodes`),
      );
      setItems(body.episodes);
      setError(undefined);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "无法连接 API");
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const refreshApprovals = useCallback(async () => {
    if (!approvalToken) {
      setApprovals([]);
      return;
    }
    try {
      const body = await readJson<{ approvals: ApprovalRecord[] }>(
        await fetch(`${apiUrl}/v1/approvals`, {
          headers: { authorization: `Bearer ${approvalToken}` },
        }),
      );
      setApprovals(body.approvals);
      setApprovalStatus(
        body.approvals.length === 0
          ? "当前没有待审批 Tool Attempt"
          : `待审批 ${body.approvals.length} 项`,
      );
    } catch (caught) {
      setApprovalStatus(caught instanceof Error ? caught.message : "审批列表加载失败");
    }
  }, [approvalToken]);

  useEffect(() => {
    void refreshApprovals();
    const interval = setInterval(() => void refreshApprovals(), 2_000);
    return () => clearInterval(interval);
  }, [refreshApprovals]);

  const openTimeline = async (episodeId: string) => {
    try {
      const body = await readJson<{ timeline: Timeline }>(
        await fetch(`${apiUrl}/v1/episodes/${episodeId}/timeline`),
      );
      setSelected(body.timeline);
      setError(undefined);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "时间线加载失败");
    }
  };

  const saveMode = async () => {
    try {
      const response = await fetch(
        `${apiUrl}/v1/source-modes/${encodeURIComponent(sourceId)}/${encodeURIComponent(cueType)}`,
        {
          method: "PUT",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ mode }),
        },
      );
      const body = (await response.json()) as {
        code?: string;
        missingRequirements?: string[];
        sourceMode?: { mode: string };
      };
      if (!response.ok) {
        setModeStatus(
          body.missingRequirements
            ? `门槛未满足：${body.missingRequirements.join(" · ")}`
            : (body.code ?? "保存失败"),
        );
        return;
      }
      setModeStatus(`已保存 ${body.sourceMode?.mode ?? mode}`);
    } catch {
      setModeStatus("无法连接 API");
    }
  };

  const rememberApprovalToken = (value: string) => {
    setApprovalToken(value);
    if (value) sessionStorage.setItem("wakeoncue.approvalToken", value);
    else sessionStorage.removeItem("wakeoncue.approvalToken");
  };

  const decideApproval = async (attemptId: string, decision: "APPROVE_ONCE" | "DENY") => {
    try {
      await readJson(
        await fetch(`${apiUrl}/v1/approvals/${attemptId}`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${approvalToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ decision }),
        }),
      );
      setApprovalStatus(
        decision === "APPROVE_ONCE" ? "已批准一次；Permit 等待 PEP 原子消费" : "已拒绝",
      );
      await refreshApprovals();
    } catch (caught) {
      setApprovalStatus(caught instanceof Error ? caught.message : "审批操作失败");
    }
  };

  return (
    <main>
      <header>
        <div>
          <p className="eyebrow">Cue → Decide → Wake</p>
          <h1>WakeOnCue</h1>
          <p className="lede">现实事件驱动的 Agent 主动唤醒与授权时间线。</p>
        </div>
        <button className="secondary" onClick={() => void refresh()}>
          刷新
        </button>
      </header>

      {error ? <div className="error">API：{error}</div> : null}

      <section className="mode-panel" aria-labelledby="mode-title">
        <div>
          <p className="kicker">运行策略</p>
          <h2 id="mode-title">Source + Cue Type 模式</h2>
          <p>Notify/Wake 必须先满足 Shadow 真实数据与安全 conformance 门槛。</p>
        </div>
        <div className="mode-controls">
          <label>
            Source
            <input value={sourceId} onChange={(event) => setSourceId(event.target.value)} />
          </label>
          <label>
            Cue Type
            <input value={cueType} onChange={(event) => setCueType(event.target.value)} />
          </label>
          <label>
            Mode
            <select value={mode} onChange={(event) => setMode(event.target.value as typeof mode)}>
              <option value="SHADOW">Shadow</option>
              <option value="NOTIFY">Notify</option>
              <option value="WAKE">Wake</option>
            </select>
          </label>
          <button onClick={() => void saveMode()}>保存模式</button>
        </div>
        <div className="gate-status">{modeStatus}</div>
      </section>

      <section className="approval-panel" aria-labelledby="approval-title">
        <div className="section-heading">
          <div>
            <p className="kicker">Human authorization</p>
            <h2 id="approval-title">一次性审批</h2>
            <p>批准只绑定当前 Agent、目标、工具与精确参数摘要；参数变化必须重新审批。</p>
          </div>
          <label className="approval-token">
            Approval Admin Token
            <input
              type="password"
              autoComplete="off"
              value={approvalToken}
              onChange={(event) => rememberApprovalToken(event.target.value)}
              placeholder="仅保存在本页 sessionStorage"
            />
          </label>
        </div>
        <div className="gate-status">{approvalStatus}</div>
        <div className="approval-list">
          {approvals.map((approval) => (
            <article className="approval-card" key={approval.attempt.attemptId}>
              <div className="approval-card-heading">
                <div>
                  <small>
                    {timestamp(approval.attempt.createdAt)} · {approval.reasonCode}
                  </small>
                  <h3>{approval.task?.contract.goal ?? approval.attempt.taskId}</h3>
                </div>
                <span className="decision OBSERVE_MORE">WAITING_APPROVAL</span>
              </div>
              <dl>
                <div>
                  <dt>Agent</dt>
                  <dd>{approval.attempt.agentRunId}</dd>
                </div>
                <div>
                  <dt>工具</dt>
                  <dd>{approval.attempt.tool}</dd>
                </div>
                <div>
                  <dt>目标对象</dt>
                  <dd>{approval.attempt.risk.destination ?? "未声明"}</dd>
                </div>
                <div>
                  <dt>可逆性</dt>
                  <dd>{approval.attempt.risk.reversible ? "可逆" : "不可逆或未知"}</dd>
                </div>
                <div>
                  <dt>费用</dt>
                  <dd>{approval.attempt.risk.estimatedCost ?? "未声明"}</dd>
                </div>
                <div>
                  <dt>等待上限</dt>
                  <dd>由 Runtime PEP 的短时暂停窗口限制</dd>
                </div>
              </dl>
              <details>
                <summary>精确参数与 digest</summary>
                <pre>{JSON.stringify(approval.attempt.arguments, null, 2)}</pre>
                <code>{approval.attempt.argumentsDigest}</code>
              </details>
              <div className="approval-actions">
                <button
                  onClick={() => void decideApproval(approval.attempt.attemptId, "APPROVE_ONCE")}
                >
                  批准一次
                </button>
                <button
                  className="danger"
                  onClick={() => void decideApproval(approval.attempt.attemptId, "DENY")}
                >
                  拒绝
                </button>
              </div>
            </article>
          ))}
        </div>
      </section>

      <div className="workspace">
        <section aria-labelledby="episodes-title">
          <div className="section-heading">
            <div>
              <p className="kicker">World state</p>
              <h2 id="episodes-title">Cue / Episode</h2>
            </div>
            <span className="count">{items.length}</span>
          </div>
          <div className="episode-list">
            {items.length === 0 ? (
              <p className="empty">
                还没有 Cue。签名 Webhook 或 Omi finalized fixture 进入后会出现在这里。
              </p>
            ) : (
              items.map((item) => (
                <button
                  className="episode-card"
                  key={item.episode.episodeId}
                  onClick={() => void openTimeline(item.episode.episodeId)}
                >
                  <div>
                    <strong>
                      {item.latestDecision?.signals?.commitment ?? item.episode.types?.[0] ?? "Cue"}
                    </strong>
                    <small>{timestamp(item.episode.lastOccurredAt)}</small>
                  </div>
                  <span
                    className={`decision ${item.latestDecision?.decision?.decision ?? "PENDING"}`}
                  >
                    {item.latestDecision?.decision?.decision ?? "PENDING"}
                  </span>
                </button>
              ))
            )}
          </div>
        </section>

        <section aria-labelledby="timeline-title">
          <div className="section-heading">
            <div>
              <p className="kicker">Evidence chain</p>
              <h2 id="timeline-title">Decision 时间线</h2>
            </div>
          </div>
          {!selected ? (
            <p className="empty">选择一个 Episode 查看 Cue、证据、reason codes 与策略版本。</p>
          ) : (
            <div className="timeline">
              {selected.cues.map((cue) => (
                <article className="timeline-item" key={cue.eventId}>
                  <span className="dot cue" />
                  <div>
                    <small>{timestamp(cue.occurredAt)} · Cue received</small>
                    <h3>{cue.type}</h3>
                    <p>
                      {cue.source.adapter} / {cue.source.sourceId}
                    </p>
                    <code>{cue.eventId}</code>
                  </div>
                </article>
              ))}
              {selected.decisions.map((evaluation) => (
                <article className="timeline-item" key={evaluation.decision.decisionId}>
                  <span className="dot decision-dot" />
                  <div>
                    <small>
                      {evaluation.mode} · {evaluation.disposition}
                    </small>
                    <h3>{evaluation.decision.decision}</h3>
                    <div className="reason-list">
                      {evaluation.decision.reasonCodes.map((reason) => (
                        <span key={reason}>{reason}</span>
                      ))}
                    </div>
                    <p>
                      {evaluation.signals.deadline
                        ? `截止 ${evaluation.signals.deadline}`
                        : "未提取截止时间"}
                      {evaluation.signals.recipient
                        ? ` · 对象 ${evaluation.signals.recipient}`
                        : ""}
                    </p>
                    <code>{evaluation.decision.strategyVersion}</code>
                  </div>
                </article>
              ))}
              <div className="evidence-box">
                <strong>证据引用</strong>
                {selected.episode.evidenceRefs.map((reference) => (
                  <code key={reference}>{reference}</code>
                ))}
              </div>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
