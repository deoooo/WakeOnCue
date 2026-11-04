# iPhone → Mac 回传协议（第 1 版）

> 状态：Mac 端已实现（`macos/WakeOnCue/Sync/`），iPhone 端待做。消息定义在 `SyncProtocol.swift`，这个文件只依赖 Foundation 和 Network，iPhone 端可以直接共用。

## 目标

手表和 iPhone 的录音在 iPhone 连上 Mac 所在的局域网后自动转给 Mac；只走本地网络，加密，Mac 确认收到后 iPhone 才删除；断了能续传。

## 配对

1. Mac 在 设置 › 设备与回传 显示二维码，内容是 `wakeoncue://pair?p=<base64url(JSON)>`，JSON 字段：

   | 字段 | 说明 |
   | --- | --- |
   | `version` | 协议版本，目前是 1 |
   | `macID`、`macName` | 这台 Mac 的稳定 ID 和名称 |
   | `service` | Bonjour 服务名，类型 `_wakeoncue._tcp` |
   | `host`、`port` | 备用地址（`xxx.local` 和端口），Bonjour 找不到时用 |
   | `identity` | 分给这台 iPhone 的 PSK 身份，也是它之后的设备 ID |
   | `key` | 32 字节随机密钥，base64url |
   | `expires` | 二维码失效时间（5 分钟） |

2. iPhone 扫码后把 `macID`、`identity`、`key` 存进自己的钥匙串，然后连接并发 `hello`。Mac 收到用这个身份发来的第一个 `hello` 就记为已配对，二维码随即作废；之后同一身份和密钥长期有效，直到在 Mac 上取消配对。
3. 每台 iPhone 一把独立的密钥。取消配对后，Mac 不再接受这把密钥。

## 传输层

- TCP + TLS 1.2 PSK，密码套件 `TLS_PSK_WITH_AES_128_GCM_SHA256`（`SyncProtocol.parameters(keys:)`，两端用同一个函数）。
- 密钥不对时握手失败（服务端日志是 `bad MAC`）。**iPhone 端注意：** Network.framework 遇到这种 TLS 错误会进入 `.waiting` 而不是 `.failed`，`send` 不会返回。要在 `stateUpdateHandler` 里看到 `.waiting(TLS 错误)` 就取消连接，并提示“需要重新配对”。
- 发现：先用 Bonjour 浏览 `_wakeoncue._tcp` 下名为 `service` 的服务；找不到再连 `host:port`。Mac 会尽量沿用同一个端口。

## 消息

每条消息：4 字节大端头长度 + JSON 头（≤ 64 KB）+ `bodyLength` 字节正文（只有 `chunk` 有正文，≤ 1 MB）。JSON 是 Swift `Codable` 对枚举的默认编码，日期是 ISO 8601。

| 方向 | 消息 | 说明 |
| --- | --- | --- |
| iPhone → Mac | `hello(deviceID, deviceName, protocolVersion)` | 连接后第一条。`deviceID` 就是配对时的 `identity` |
| Mac → iPhone | `welcome(macName, accepting, drop)` | `accepting` 是 Mac 上「自动回传」开关；`drop` 是最近 30 天里 Mac 上标为私人或已删除的时段，落在这些时段里的音频 iPhone 直接丢弃，不发送 |
| iPhone → Mac | `offer(SegmentInfo)` | 要发的一段：`id`（稳定唯一，如 `watch-<session>-0003`，只能用字母数字和 `-_.`）、`source`（`watch` / `iphone`）、`recordingID`、`index`、`startedAt`（真实开始时间）、`duration`、`bytes`、`sha256`（小写十六进制）、`format`（如 `m4a`） |
| Mac → iPhone | `resume(segmentID, offset, complete)` | 从 `offset` 继续发；`complete` 为真表示 Mac 早已存好，iPhone 可以直接删 |
| iPhone → Mac | `chunk(segmentID, offset, bodyLength)` + 正文 | `offset` 必须等于 Mac 已收到的字节数 |
| iPhone → Mac | `commit(segmentID)` | 发完了 |
| Mac → iPhone | `stored(segmentID)` | 大小和 SHA-256 都对，已入库。**iPhone 只在收到这条后删除自己那份** |
| 双向 | `failure(segmentID, reason, retry)` | `retry` 为真时稍后重试（比如 Mac 关了自动回传、偏移量不对、校验失败）；为假时不要重试（比如版本不兼容、未配对） |
| iPhone → Mac | `bye` | 正常结束 |

## Mac 端如何保存

- 收到一半的内容在 `~/Library/Application Support/WakeOnCue/Inbox/.partial/`，重连后从那里续传。
- 校验通过后移到 `Inbox/<deviceID>/<segmentID>.<format>`，记入 `remote_segment` 表（`merged = 0`），随即合并。

## 合并（Mac 端，`Sync/Merger.swift`）

1. 按 `startedAt` 加上这台设备已知的时钟偏差，放到时间线上。
2. 和 Mac 麦克风同一时段（前后各多取 3 秒）比较：把两边都算成 20 毫秒一帧的对数音量包络，在 ±3 秒内找相关性最高的错位，相关系数用 Pearson，只算 Mac 录到的帧。
3. 重叠至少 10 秒且相关系数 ≥ 0.5：**内容相同**。错位就是时钟偏差，记下来（平滑更新）；Mac 录到的部分丢弃，只把 Mac 没录到、至少 1 秒的空档补进来。
4. 相关系数低，或重叠不够 10 秒，或关掉了「内容相同时自动合并」：**内容不同**，整段保留，用已知的时钟偏差对齐。
5. 落在暂停、私人、已删除时段里的部分丢弃。
6. 保留下来的音频写成和 Mac 自己一样的 AAC 分段（通道 `remote`，来源「Apple Watch」或「iPhone」），离线转录，说话人默认是「我」，并重新生成受影响小时的总结。
7. `remote_segment.outcome` 记下结果：`duplicate`（和 Mac 相同，全部丢弃）、`filled`（补了空档）、`kept`（两边都保留）、`dropped`（全在不录音的时段里）、`unreadable`。

## 尚未包含

- 暂停时段：Mac 暂停时记一条 `paused` 标记，`drop` 里会带上，合并时也会丢弃。
- 删除同步回 iPhone 和手表：已删除的时段通过 `drop` 让 iPhone 不再发送；iPhone 本地的删除和“最近删除”同步留到 5b。
