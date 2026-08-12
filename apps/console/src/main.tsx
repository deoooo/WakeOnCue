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

function timestamp(value: string): string {
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
                      {item.latestDecision?.signals.commitment ?? item.episode.types[0]}
                    </strong>
                    <small>{timestamp(item.episode.lastOccurredAt)}</small>
                  </div>
                  <span
                    className={`decision ${item.latestDecision?.decision.decision ?? "PENDING"}`}
                  >
                    {item.latestDecision?.decision.decision ?? "PENDING"}
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
