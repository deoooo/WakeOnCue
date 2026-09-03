# Realtime Processing

WakeOnCue 的实时分析是一条可失败的旁路，不能成为录音链路的依赖：

```text
                                  ┌→ source.caf → 10s AAC chunks → local / S3
iPhone microphone → 24 kHz mono ──┤
                                  └→ 0.5s PCM frames → Realtime Gateway → Processor
                                                                     ↓
                                      iPhone live transcript ← versioned events
```

Gateway 是 App 唯一固定依赖。当前 Processor 可以运行在 Mac，后续可以换成云 GPU、Kubernetes worker 或第三方服务，而无需修改 iOS 协议。Gateway 不运行 ASR，也不轮询 R2；R2 的完整 `source.m4a` 继续作为录音完成后的校正和补处理来源。

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

返回 `session_id`、短期 `session_token` 和 `websocket_url`。WebSocket 使用 `Authorization: Bearer <session-token>`，token 不放在 URL 中。

App 发送：

- `audio.append`：0.5 秒 PCM、sequence、start_ms、base64 音频；
- `session.pause` / `session.resume` / `session.finish`；
- `session.replay`：携带最后收到的 revision，重连后补放文字事件。

Processor 返回：

- `transcript.upsert`：相同 `segment_id` 可被更高 revision 修订；
- `speaker.corrected`：后续 diarization 或身份匹配可以纠正说话人；
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
    "person_id": null,
    "display_name": "Speaker 1",
    "confidence": 0.87
  }
}
```

Gateway 为每个会话分配单调递增的 revision，并保留最近 500 个可重放事件。音频帧不会在 Gateway 持久化；Processor 离线期间实时文字可能缺失，但本地录音不会缺失，完整录音可在结束后从 S3 补处理。

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

Whisper 回退路径使用 16 秒窗口、4 秒步进，按词级时间戳只发布新内容；自动模式会在第一次可靠检测后锁定本次录音语言。低可信静音、异常压缩率和机械重复片段会被过滤。说话人识别使用 sherpa-onnx 的公开 pyannote segmentation ONNX 与 3D-Speaker embedding 模型；实时字幕先出现，滚动 diarization 完成后以 `speaker.corrected` 把 Unknown speaker 修订成 Speaker 1/2/3。

模型来源和 Python API 示例见 [sherpa-onnx 官方示例](https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-speaker-diarization.py)。默认自动估算人数；已知固定参会人数时可提高聚类稳定性：

```bash
wakeoncue-mac-processor --gateway http://127.0.0.1:8090 --speaker-count 4
```

实时处理使用约 30 秒的有限滚动窗口（20 秒推进、10 秒重叠），不会随会议时长反复重算全部音频。跨窗口 speaker label 通过 512 维声纹 embedding 匹配到稳定 cluster。自动聚类阈值默认 0.95，以降低真实手机麦克风和扬声器回放环境中的过度拆分。这里的 Speaker 1/2 表示“同一个声音的人”，并不等于真实姓名；真实姓名需要后续增加用户确认或声纹 enrollment。可通过 `--diarization-interval`、`--diarization-overlap` 和 `--speaker-clustering-threshold` 调整延迟与稳定性的取舍。

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
`RecordingData/recordings/<recording_id>/transcript.json`. When S3 is enabled, the
finished transcript is also queued through the durable uploader and stored at
`recordings/<recording_id>/transcript.json`, beside `source.m4a`. Opening a recording
restores a missing local transcript from S3 and caches the real JSON file locally.
Retranscription replaces the local transcript and uploads a new version to the same
object key. Audio retention cleanup does not delete transcript JSON.

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

只替换 Processor 部署和模型实现。后处理 worker 可订阅录音完成事件或对象存储事件，读取完整 `source.m4a`，再通过相同 revision/upsert 语义生成最终校正版 transcript。
