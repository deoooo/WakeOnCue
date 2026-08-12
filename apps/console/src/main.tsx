import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "./styles.css";

function App() {
  return (
    <main>
      <header>
        <p className="eyebrow">Cue → Decide → Wake</p>
        <h1>WakeOnCue</h1>
        <p>现实事件驱动的 Agent 主动唤醒与授权时间线。</p>
      </header>
      <section aria-labelledby="bootstrap-title">
        <h2 id="bootstrap-title">Bootstrap ready</h2>
        <p>
          Console 已启动。Cue、Decision、Task、Approval、Outcome 和 Replay 视图将在后续 checkpoint
          接入真实 API。
        </p>
        <span className="status">Shadow default · Live Wake off</span>
      </section>
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
