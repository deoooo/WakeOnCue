# 提问与 MCP

WakeOnCue 有两种方式就录音内容提问，二者都要求「回答必须附带来源」：

1. **iPhone 上的「向录音提问」**：默认完全在本机完成；如果配置了[第三方模型](ai-providers.md)，匹配片段会发给该服务。
2. **自托管 MCP 服务**：让 Claude Desktop、Claude Code 等 MCP 客户端只读访问 S3 里已有的转写文字。
   Gateway 或 Mac 一直在线，所以客户端访问时不需要唤醒 iPhone。

## iPhone：向录音提问

入口：首页「最近录音」右侧的「提问」，或「全部录音」右上角的气泡按钮。

1. **检索**：只读取本机 `RecordingData/recordings/<id>/transcript.json` 和 `summary.json`，
   不下载音频或远端转写。英文按单词匹配，中文、日文、韩文按相邻两个字匹配，所以不需要嵌入模型。
   取得分最高的 8 段。
2. **回答**：iOS 26 且 Apple 智能可用时，用设备端 Foundation Models 生成回答。提示词只包含编号的
   检索段落（约 3000 字以内，超出上下文窗口时自动减半重试），并要求模型只能依据这些段落作答；
   如果段落答不了，模型会标记为「无法回答」，界面会明说并只列出匹配段落。
3. **来源**：每条来源显示录音标题、时间戳、说话人和原文引用。说话人名称按
   本录音的改名 → 已保存声音的人名 → 处理器的匿名标签决定，人名只在本机使用。
   点击来源会打开录音详情并从该时间开始播放。
4. **没有 Apple 智能**：不生成回答，只显示匹配段落。
5. **什么都没找到**：明确告诉用户本机转写里没有相关内容，不会编造回答。

## MCP 服务

### 提供的工具（只读）

| 工具 | 参数 | 返回 |
| --- | --- | --- |
| `search_transcripts` | `query`，`limit`（默认 10，最多 50） | `citations`：`recording_id`、`recording_title`、`recording_started_at`、`segment_id`、`start_ms`、`end_ms`、`timestamp`、`speaker`、`text`、`score`；以及 `found` |
| `get_recording` | `recording_id` | 标题、开始时间、时长、设备端摘要（如有）和带时间戳的全部分段 |
| `list_recordings` | `since`（ISO 8601 日期或时间，可选），`limit`（默认 20，最多 200） | 按开始时间倒序的录音列表 |

v1 没有任何写入工具。每个工具结果同时给出 `structuredContent` 和等价的 JSON 文本。

### 读取什么、不读取什么

> **iPhone 已不再上传到 S3，也不再连接 Gateway**，新录音不会出现在 MCP 里。这里只能检索旧版本已备份的内容，或你用其他方式写入同样结构的对象。

服务只读取 S3 中的这些对象：

```text
<prefix>/recordings/<recording_id>/metadata.json    # 开始时间、标题
<prefix>/recordings/<recording_id>/transcript.json  # [RealtimeTranscriptEvent]
<prefix>/recordings/<recording_id>/summary.json     # RecordingSummary（如存在）
```

- 从不读取 `source.m4a`、`chunks/` 或其他音频，Gateway 也不保存音频。
- 输出字段是白名单：只有分段 ID、时间、文字和处理器给出的匿名说话人标签（如 `Speaker 1`）。
  `person_id`、`cluster_id`、置信度、任何声纹或嵌入字段、`metadata.json` 里的存储桶信息都不会返回。
  已保存声音对应的人名只存在 iPhone 上，MCP 无从得知。
- 对象按 ETag 缓存在内存里，默认每 30 秒最多重新列一次目录，只重新下载变化的文件。

### 运行

推荐挂在已有的 Realtime Gateway 上，共用同一个 Bearer token。设置 `WAKEONCUE_MCP_S3_BUCKET`
后 Gateway 会在 `/mcp` 提供 MCP；不设置则没有这个路由。

```bash
export WAKEONCUE_REALTIME_API_TOKEN="$(openssl rand -hex 32)"
export WAKEONCUE_MCP_S3_BUCKET=my-wakeoncue-bucket
export WAKEONCUE_MCP_S3_REGION=auto                       # R2 用 auto
export WAKEONCUE_MCP_S3_ENDPOINT_URL=https://<account>.r2.cloudflarestorage.com
export WAKEONCUE_MCP_S3_PREFIX=wakeoncue                   # 与旧版本 iPhone 设置里的前缀一致
export AWS_ACCESS_KEY_ID=...                               # 建议使用只读 key
export AWS_SECRET_ACCESS_KEY=...
PYTHONPATH=server python3 -m recording_service.realtime_main
```

也可以单独运行（默认 `127.0.0.1:8091`）：

```bash
WAKEONCUE_MCP_API_TOKEN=... WAKEONCUE_MCP_S3_BUCKET=... PYTHONPATH=server python3 -m recording_service.mcp_server
```

| 环境变量 | 说明 |
| --- | --- |
| `WAKEONCUE_MCP_S3_BUCKET` | 必填，保存转写的存储桶 |
| `WAKEONCUE_MCP_S3_REGION` | 默认 `us-east-1` |
| `WAKEONCUE_MCP_S3_ENDPOINT_URL` | R2、MinIO 等兼容服务的地址 |
| `WAKEONCUE_MCP_S3_PREFIX` | 默认 `wakeoncue` |
| `WAKEONCUE_MCP_S3_FORCE_PATH_STYLE` | `true` 时使用 path-style 地址（MinIO 常用） |
| `WAKEONCUE_MCP_REFRESH_SECONDS` | 目录刷新间隔，默认 30 |
| `WAKEONCUE_MCP_ALLOWED_ORIGINS` | 允许的浏览器 Origin，逗号分隔；默认只允许同源 |
| `WAKEONCUE_MCP_API_TOKEN` / `WAKEONCUE_MCP_HOST` / `WAKEONCUE_MCP_PORT` | 仅单独运行时使用 |

凭证走 boto3 的标准链（环境变量、`AWS_PROFILE`、实例角色等）。服务只调用 `ListObjectsV2` 和
`GetObject`，所以给它一把只有读取权限、并限定到该前缀的 key 即可。

### 传输与安全

- MCP 规范 2025-06-18 的 Streamable HTTP：`POST /mcp` 收发单条 JSON-RPC 2.0 消息，以
  `application/json` 回复；通知返回 `202`。不提供 SSE 流，`GET`/`DELETE` 返回 `405`。
- 每个请求都要带 `Authorization: Bearer <token>`，否则 `401`。
- 带有非同源 `Origin` 的请求返回 `403`，防止 DNS rebinding。
- 不支持的 `MCP-Protocol-Version` 返回 `400`；同时接受 `2025-03-26`。
- 对外开放时请放在 HTTPS 反向代理或 Tailscale 等私有网络后面，不要使用默认 token。

### 接入 Claude Code

```bash
claude mcp add --transport http wakeoncue https://gateway.example.com/mcp --header "Authorization: Bearer $WAKEONCUE_REALTIME_API_TOKEN"
```

然后在 Claude Code 中运行 `/mcp` 确认 `wakeoncue` 已连接，可以问「上周预算会议定了什么？请附上录音和时间」。

### 接入 Claude Desktop

Claude Desktop 可在 **设置 → Connectors** 添加远程 MCP 服务器（需要可从公网访问的 HTTPS 地址）。
如果只想本机使用，可以在 `claude_desktop_config.json` 里通过 `mcp-remote` 桥接，并带上 token：

```json
{
  "mcpServers": {
    "wakeoncue": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://127.0.0.1:8090/mcp",
        "--header",
        "Authorization: Bearer ${WAKEONCUE_TOKEN}"
      ],
      "env": { "WAKEONCUE_TOKEN": "<gateway-token>" }
    }
  }
}
```

### 手动检查

```bash
curl -s http://127.0.0.1:8090/mcp \
  -H "Authorization: Bearer $WAKEONCUE_REALTIME_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_transcripts","arguments":{"query":"预算"}}}'
```

## 测试

```bash
PYTHONPATH=server python3 -m unittest discover -s server/tests
```

iOS 的检索与引用逻辑在 `WakeOnCueTests/RecordingQuestionAnsweringTests.swift`。
