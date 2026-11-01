# Realtime Processing

> **iPhone 已不再接入 Gateway。** 实时字幕、说话人区分和声纹功能已从 iPhone App 移除，本文描述的协议现在只供 Mac 菜单栏 App 在本机使用；涉及 iPhone 配对、局域网发现和声纹登记的部分是旧设计。iPhone 的转写和摘要见[第三方服务说明](ai-providers.md)。

WakeOnCue 的实时分析是一条可失败的旁路，不能成为录音链路的依赖：

```text
                                  ┌→ source.caf → 10s AAC chunks → local
iPhone microphone → 24 kHz mono ──┤
                                  └→ 0.5s PCM frames → Realtime Gateway → Processor
                                                                     ↓
                                      iPhone live transcript ← versioned events
```

Gateway 是 App 唯一固定依赖。当前 Processor 可以运行在 Mac，后续可以换成云 GPU、Kubernetes worker 或第三方服务，而无需修改 iOS 协议。Gateway 不运行 ASR。

## Protocol v1

App 使用长期 Gateway token 创建短期会话：

```http
POST /v1/realtime/sessions
Authorization: Bearer <gateway-token>
Content-Type: application/json
```

```json
{
  "protocol_version": 1,
  "recording_id": "rec_xxx",
  "language": "zh-Hans",
  "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}
}
```

可选字段 `speaker_diarization` 与 `known_voiceprints` 控制是否区分说话人以及可识别的已保存声音，见下方[区分说话人与记住声音](#区分说话人与记住声音)。

返回 `session_id`、短期 `session_token` 和 `websocket_url`。WebSocket 使用 `Authorization: Bearer <session-token>`，token 不放在 URL 中。

App 发送：

- `audio.append`：0.5 秒 PCM、sequence、start_ms、base64 音频；
- `session.pause` / `session.resume` / `session.finish`；
- `session.replay`：携带最后收到的 revision，重连后补放文字事件。

Processor 返回：

- `transcript.upsert`：相同 `segment_id` 可被更高 revision 修订；
- `speaker.corrected`：后续 diarization 修订说话人簇，匹配上已保存声音时带 `person_id`；
- `session.completed`：本次实时处理结束。

字幕示例：

```json
{
  "protocol_version": 1,
  "type": "transcript.upsert",
  "recording_id": "rec_xxx",
  "segment_id": "seg_018",
  "revision": 3,
  "start_ms": 18200,
  "end_ms": 23600,
  "text": "我们下周一开始灰度。",
  "is_final": true,
  "speaker": {
    "cluster_id": "speaker_1",
    "person_id": "self",
    "display_name": "Speaker 1",
    "confidence": 0.87
  }
}
```

Gateway 为每个会话分配单调递增的 revision，并保留最近 500 个可重放事件。音频帧不会在 Gateway 持久化；Processor 离线期间实时文字可能缺失，但本地录音不会缺失，完整录音可在结束后重新转写。

## 多声道录音（Mac 线上会议）

Mac 菜单栏 App 录线上会议时有两路声音：麦克风（用户本人）和这台 Mac 播放的声音（会议里的其他人）。协议用「每个声道一个会话」表示，而不是把两路混成一路：

- 两个会话使用**同一个 `recording_id`**，创建时各带可选字段 `"channel": "microphone"` 或 `"channel": "system"`。不带 `channel` 的会话（iPhone 现有行为）完全不变；其他取值返回 422。
- 两个会话的音频从同一时刻开始计时：较晚收到第一帧的声道在开头补静音，所以两边的 `start_ms` 在同一时间轴上，可以直接按时间合并。
- **`microphone`**：本身就是用户，Gateway 强制关闭这个会话的 `speaker_diarization`、清空 `known_voiceprints`，并把发出的每条 `transcript.upsert` / `speaker.corrected` 的 `speaker` 改写为 `{"cluster_id": "microphone", "person_id": "self", "display_name": "Me"}`。不需要声纹。
- **`system`**：只有其他参会者。用户开了区分说话人时照常匿名分簇（Speaker 1 / 2 / …）；Gateway 移除 `person_id = "self"` 的已保存声音，并把任何 `person_id: "self"` 的结果改回 `null`，防止扬声器回声把对方认成「我」。
- Gateway 在 `session.started` 里把 `channel` 转给 Processor，并在发给客户端的事件上加 `channel`。`segment_id` 只在各自会话内唯一，客户端以 `(channel, segment_id)` 作为一句话的键，`revision` 仍按会话递增。

```json
{"protocol_version": 1, "recording_id": "rec_mac_3f2a…", "channel": "microphone",
 "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}}
```

```json
{"protocol_version": 1, "type": "transcript.upsert", "recording_id": "rec_mac_3f2a…",
 "channel": "system", "segment_id": "seg_4200", "revision": 7, "start_ms": 4200, "end_ms": 7900,
 "text": "下周一上线。", "is_final": true,
 "speaker": {"cluster_id": "speaker_1", "person_id": null, "display_name": "Speaker 1"}}
```

选择两个会话的原因：Processor 不需要改动就能并行处理（每个会话独立的 ASR 缓冲和断句），旧 Processor 也能用，说话人标注由 Gateway 统一保证；代价是 Processor 的计算量翻倍。系统声音用 Core Audio process tap（macOS 14.4+，私有、不静音、单声道混音）录制，需要用户在「隐私与安全性 › 录屏与系统录音」允许。录音以本地 `microphone.caf` / `system.caf` 为准，网络或 Processor 故障只会缺少实时文字。

## Run the current Mac implementation

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[mac-processor]'
python scripts/download_diarization_models.py

export WAKEONCUE_REALTIME_API_TOKEN='replace-with-a-long-random-token'
wakeoncue-realtime-gateway
```

在另一个终端启动 Mac Processor：

```bash
cd server
source .venv/bin/activate
export WAKEONCUE_REALTIME_API_TOKEN='same-token'
wakeoncue-mac-processor --gateway http://127.0.0.1:8090 --backend whisper
```

## Pair an iPhone with a self-hosted Gateway

WakeOnCue pairing payloads use this versioned JSON contract:

```json
{
  "type": "wakeoncue.realtime-gateway",
  "version": 1,
  "gateway_url": "https://gateway.example.com",
  "gateway_token": "the-existing-gateway-bearer-token"
}
```

`gateway_url` must be an HTTP or HTTPS base URL without embedded credentials, query,
or fragment. `gateway_token` is the existing long-lived Gateway bearer token. Pairing
does not make it short-lived and the App does not describe it as expiring. The JSON and
QR code must therefore be handled as secrets.

Create the JSON and a real QR PNG from a token already held in an environment variable:

```bash
cd server
export WAKEONCUE_REALTIME_API_TOKEN='same-token-used-by-the-gateway'
python scripts/generate_realtime_pairing.py \
  --url 'https://gateway.example.com' \
  --token-env WAKEONCUE_REALTIME_API_TOKEN \
  --json-output .runtime/pairing.json \
  --qr-output .runtime/pairing.png
```

Or read the token from a private file with `--token-file /path/to/token`. The command
never accepts the token itself as a command-line argument and never prints the token or
payload. Both output files are created with owner-only permissions. Delete them after
pairing.

In iOS Settings, enable Live transcription, choose Pair self-hosted service, then scan
the QR or paste the complete JSON. The App shows the URL, transport, and a masked token
for explicit review. Verify and save calls the authenticated `/v1/realtime/validate`
endpoint before anything is persisted. A scanned or stored token alone is not treated
as proof that the service is currently reachable. Local recording remains the source of
truth if transcription is disabled or unavailable.

也可以不用终端：Mac 菜单栏 App（`ios/WakeOnCueMac`，见 README）以同样的参数启动 Gateway 和 Processor，用 Bonjour 广播，并在 App 内用 CoreImage 生成同一格式的配对二维码（只在用户点击后显示，不写文件）。

当前 Mac Processor 默认使用 `Qwen3-ASR-1.7B`。建议单独使用 Python 3.12 环境，避免 Qwen/PyTorch 与 MLX 的依赖互相影响：

```bash
cd server
uv venv --python 3.12 .venv-qwen
uv pip install --python .venv-qwen/bin/python -e '.[qwen-processor]'
export WAKEONCUE_QWEN_MODEL='/absolute/path/to/Qwen3-ASR-1.7B'
.venv-qwen/bin/python -m recording_service.mac_processor \
  --gateway http://127.0.0.1:8090 --backend qwen
```

模型在 Processor 启动时加载一次并驻留内存。每句话在约 4 秒时发布初稿，随着音频增长使用相同 `segment_id` 原位修订；检测到约 0.7 秒停顿或达到 16 秒上限后定稿。语言未被用户明确指定时，每句话独立自动检测，因此普通话、英语和粤语可以在同一录音中切换。会话结束时会用已完成的句子和上下文再校正一次。`WAKEONCUE_ASR_GLOSSARY` 可提供会议专有名词；`WAKEONCUE_ASR_BACKEND=whisper` 可立即回退到 MLX Whisper。

Whisper 回退路径使用 16 秒窗口、4 秒步进，按词级时间戳只发布新内容；自动模式会在第一次可靠检测后锁定本次录音语言。低可信静音、异常压缩率和机械重复片段会被过滤。

## 区分说话人与记住声音

做法参照 AideMemo：默认不区分；用户开启后按「说话人 1 / 2 / …」匿名区分，可以在每条录音里命名；另有一个默认关闭的「记住声音」，用于在之后的录音里自动认出已命名的人。

- **区分说话人（默认关闭）**：iOS 设置 › 说话人。开启后会话请求带 `"speaker_diarization": true`，Processor 才运行 diarization；不带时不做任何说话人分析，字幕保持 Unknown speaker。
- **我的声音**：用户同意后朗读 20 秒，App 把样本发到 `POST /v1/voiceprints/enroll`，得到的声纹只存在 iPhone Keychain（`ThisDeviceOnly`，不进备份、iCloud 或 S3）。会话里以 `person_id = "self"` 下发，匹配上的那一类说话人显示为「我」。
- **命名**：在录音的「说话人名称」里输入名字，或从通讯录选择（使用系统联系人选择器，App 不需要通讯录权限）。名字只属于这条录音。
- **记住声音（默认关闭，开启前弹出生物识别说明）**：为说话人命名后可选「记住声音」。App 从这条录音里取出该说话人的片段（最多 20 秒），发到同一个登记接口，得到的声纹以随机 `person_id` 存在 iPhone Keychain。之后的会话通过 `known_voiceprints` 下发；Processor 把会话内的说话人簇与它们比对，只回传 `person_id`，名字从不离开 iPhone。一年没再听到的声音自动删除；关闭「记住声音」会删除全部已保存的声音，录音里已起的名字保留。
- **Gateway 与 Processor 不落盘**：登记样本和声纹都不保存；会话期间 Gateway 只在内存保存 `known_voiceprints`，Processor 发出 `session.completed` 后即清除。

```json
{
  "protocol_version": 1,
  "recording_id": "rec_xxx",
  "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1},
  "speaker_diarization": true,
  "known_voiceprints": [
    {"person_id": "self", "model": "3dspeaker_...", "embedding": [0.01, -0.02]},
    {"person_id": "6F1C…", "model": "3dspeaker_...", "embedding": [0.03, 0.01]}
  ]
}
```

`speaker.corrected` 事件里的 `speaker` 形如 `{"cluster_id": "speaker_2", "person_id": "self" | "<id>" | null, "display_name": "Speaker 2"}`。声纹的 `model` 与当前 Processor 的 embedding 模型不一致时，该声音被忽略（仍会匿名区分）；更换模型后需要重新登记或重新记住。

```http
POST /v1/voiceprints/enroll
Authorization: Bearer <gateway-token>

{"protocol_version": 1,
 "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1},
 "audio_base64": "<最多 25 秒 PCM>"}

200 {"protocol_version": 1, "voiceprint": {"model": "...", "embedding": [...]}, "speech_ms": 19946}
```

Processor 只取样本中时长最长的那个声音计算 embedding；不足 8 秒清晰语音时返回 422 `insufficient_speech`。Processor 通过 `processor.register` 的 `capabilities.voiceprint_model` 声明自己能计算声纹；Gateway 只把登记请求转给这样的 Processor（WebSocket 消息 `voiceprint.enroll` → `voiceprint.enrolled` / `voiceprint.failed`），没有时返回 503。

说话人分割使用 sherpa-onnx 的公开 pyannote segmentation ONNX 与 3D-Speaker embedding 模型，模型来源见 [sherpa-onnx 官方示例](https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-speaker-diarization.py)。滚动窗口约 30 秒（20 秒推进、10 秒重叠）；跨窗口通过 512 维 embedding 匹配到会话内稳定的簇。已知固定参会人数时可用 `--speaker-count` 提高稳定性；`--voice-match-threshold`（默认 0.5）控制与已保存声音匹配的余弦相似度阈值，`--speaker-clustering-threshold`（默认 0.95）、`--diarization-interval`、`--diarization-overlap` 调整分割的延迟与稳定性。用 macOS `say` 合成的两种中文声音验证时，本人相似度约 0.96、他人约 0.12；真人、远场和嘈杂环境下的阈值尚未在真机校准。

真机不能使用 `127.0.0.1` 访问 Mac。开发时可使用同一局域网地址；远程使用建议把 Gateway 部署为稳定 HTTPS/WSS 服务，或短期用 Cloudflare Tunnel 暴露 Gateway。Processor 自己只需向 Gateway 发起出站 WebSocket，不需要给 Mac 开入站端口。

### Temporary remote Mac mode

`server/scripts/run_remote_mac_stack.sh` starts a development-only remote stack:

- a Cloudflare Quick Tunnel forwarding HTTPS/WSS to the loopback-only Gateway;
- the Gateway with a random bearer token stored in macOS Keychain;
- the Qwen3-ASR (default) or MLX Whisper fallback + sherpa-onnx Mac Processor;
- `caffeinate` for the lifetime of the stack.

The included LaunchAgent template is deliberately not configured with `RunAtLoad` or
`KeepAlive`. A Quick Tunnel gets a new random hostname whenever it restarts, so silently
restarting it would leave the iPhone pointing at a stale URL. The Mac must remain awake,
online, and logged in while this temporary mode is active. Use a named Cloudflare Tunnel
with a stable hostname before treating the Mac as an unattended service.

If Clash Verge TUN mode is enabled on the Mac, add `cloudflared` as a `DIRECT` process
rule. Otherwise its port 7844 connection can be sent to a proxy that cannot carry the
Cloudflare Tunnel transport. This Mac uses HTTP/2 explicitly for predictable behavior.

## Transcript persistence

The iOS app writes the current transcript atomically beside the recording as
`RecordingData/recordings/<recording_id>/transcript.json`. Transcripts are not uploaded.
For a recording an older version backed up to S3, opening it restores a missing local
transcript from S3 and caches the real JSON file locally. Retranscription replaces the
local transcript.

## Local-first transport

The temporary Mac stack advertises `_wakeoncue._tcp` with Bonjour and publishes its
`.local` host, port, scheme, and protocol version in the TXT record. The iOS app uses
Network.framework to discover candidates. It gives Bonjour discovery a 650 ms local-only
window and uses the configured public endpoint only when no healthy LAN Gateway is found.
When a healthy Bonjour Gateway is available, the app creates the session and connects
the audio WebSocket through that LAN route, so realtime processing does not depend on
the public tunnel. Otherwise it creates the session through the configured public
Gateway. Because the session response can contain the configured public WebSocket URL,
the client preserves its session path and token but rewrites the WebSocket authority to
the selected Gateway.

On disconnect, the client tries the active endpoint, newly discovered LAN endpoints,
and the configured public Gateway while retaining the same session ID, replay revision,
and queued audio frames. `RealtimeTransport` unified logs report the selected URL. Both
addresses must terminate at the same Gateway instance so reconnect and replay remain
valid.

The development Mac script binds the Gateway to all local interfaces and keeps bearer
authentication enabled. Its Bonjour route currently uses plain HTTP/WebSocket on the
trusted LAN; this avoids the public round trip but does not provide confidentiality
against devices able to observe LAN traffic. Before treating LAN mode as a production
transport, add authenticated TLS with certificate pinning or use a private encrypted
overlay such as Tailscale. Bonjour remains an optional discovery layer, so the Processor
can later move from macOS to another host without changing the App/Gateway protocol.

If the existing Quick Tunnel must keep its current random hostname, do not restart the
legacy loopback-only stack just to enable LAN testing. `run_local_gateway_bridge.sh`
forwards LAN port 8091 to the existing loopback Gateway and advertises that bridge with
Bonjour. Remove that bridge after the main stack is restarted with native LAN binding.

The checked-in `wakeoncue.remote-mac.plist` is a path-neutral template. Replace each
`/path/to/WakeOnCue` entry with the absolute checkout path before loading it with
`launchctl`; no machine-specific paths or credentials belong in the repository.

## Migration boundary

迁移到非 Mac 环境时保持以下接口不变：

- iOS `POST /v1/realtime/sessions`；
- App WebSocket 事件格式；
- Processor 注册、`session.started`、`audio.append` 和结果事件。

只替换 Processor 部署和模型实现。

## MCP

设置 `WAKEONCUE_MCP_S3_BUCKET` 后，Gateway 会在 `/mcp` 提供只读 MCP 服务（Streamable HTTP，复用 Gateway token），让 Claude 等客户端检索 S3 中的转写文字并附带时间戳引用。它不读取音频，也不返回声纹或人名。配置和接入 Claude Code / Claude Desktop 的方法见 [提问与 MCP](mcp.md)。
