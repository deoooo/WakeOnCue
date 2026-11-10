# iPhone → Mac 回传协议（第 1 版）

> 状态：Mac 端（`macos/WakeOnCue/Sync/`）和 iPhone 端（`ios/WakeOnCue/MacLink/`）都已实现。消息定义在 `SyncProtocol.swift`，这个文件只依赖 Foundation 和 Network，iPhone 端可以直接共用。

## 目标

手表和 iPhone 的录音在 iPhone 连上 Mac 所在的局域网后自动转给 Mac；只走本地网络，加密，Mac 确认收到后 iPhone 才删除；断了能续传。

## 配对

iPhone 上的入口是 设置 › Mac › 连接 Mac：先列出附近的 Mac（配对码），也可以扫二维码（App 内扫码或系统相机）。两种方式都要等 Mac 用新密钥回了 `welcome`，iPhone 才保存配对；之前失败什么都不留。

### 配对码（附近的 Mac）

1. Mac 打开「允许附近的 iPhone 请求配对码」（默认开）时，另开一个监听，Bonjour 类型 `_wakeoncue-pair._tcp`，名称同 Mac。它用公开的 PSK（身份 `wakeoncue-pair-request`，密钥 `SHA256("WakeOnCue pair request v1")`），只回答 `pairRequest`，不接受 `hello`。
2. iPhone 浏览 `_wakeoncue-pair._tcp` 列出 Mac，用户点一台：发 `pairRequest(requestID, deviceName)`。Mac 生成 6 位配对码，开一个只认 `codeKey(配对码, requestID)`（身份 `pair-<requestID>`）的临时监听，在浮窗里显示配对码，回 `pairPending(macName, expires, port)`。同一时间只开一个请求；被拒绝的设备 1 分钟内不能再请求。
3. 用户在 iPhone 输入配对码，iPhone 用同样的方法推出密钥，连同一主机的 `port`。配对码不对 TLS 握手就失败；临时监听累计 5 次握手失败、超过 2 分钟或在 Mac 上点「拒绝」都会关闭。
4. 握手成功后 iPhone 发 `pairExchange(X25519 公钥)`，Mac 回 `pairAccepted(macID, macName, service, identity, 公钥, port)`。两边用 `pairingKey(共享密钥, requestID)` 得到长期密钥，Mac 先把这台设备加进主监听再回复。之后 iPhone 用新密钥照常连接、发 `hello`。
5. 安全性：猜配对码只能在线一次次握手，5 次即作废；事后抓包暴力破解配对码也算不出长期密钥（它来自 X25519）。

### 二维码

1. Mac 在 设置 › 设备与回传 › 用二维码配对 显示二维码，内容是 `wakeoncue://pair?p=<base64url(JSON)>`，JSON 字段：

   | 字段 | 说明 |
   | --- | --- |
   | `version` | 协议版本，目前是 1 |
   | `macID`、`macName` | 这台 Mac 的稳定 ID 和名称 |
   | `service` | Bonjour 服务名，类型 `_wakeoncue._tcp` |
   | `host`、`port` | 备用地址（`xxx.local` 和端口），Bonjour 找不到时用 |
   | `identity` | 分给这台 iPhone 的 PSK 身份，也是它之后的设备 ID |
   | `key` | 32 字节随机密钥，base64url |
   | `expires` | 二维码失效时间（5 分钟） |

2. iPhone 扫码后先确认，再用二维码里的密钥连接并发 `hello`，收到 `welcome` 后才把 `macID`、`identity`、`key` 存进钥匙串。Mac 收到用这个身份发来的第一个 `hello` 就记为已配对，二维码随即作废；之后同一身份和密钥长期有效，直到在 Mac 上取消配对。
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
| Mac → iPhone | `welcome(macName, accepting, drop, features)` | `accepting` 是 Mac 上「自动回传」开关；`drop` 是最近 30 天里 Mac 上标为私人或已删除的时段，落在这些时段里的音频和标记 iPhone 直接丢弃，不发送；`features` 是这台 Mac 认识的扩展消息（见下文），老版本 Mac 没有这个字段 |
| iPhone → Mac | `offer(SegmentInfo)` | 要发的一段：`id`（稳定唯一，如 `watch-<session>-0003`，只能用字母数字和 `-_.`）、`source`（`watch` / `iphone`）、`recordingID`、`index`、`startedAt`（真实开始时间）、`duration`、`bytes`、`sha256`（小写十六进制）、`format`（如 `m4a`） |
| Mac → iPhone | `resume(segmentID, offset, complete)` | 从 `offset` 继续发；`complete` 为真表示 Mac 早已存好，iPhone 可以直接删 |
| iPhone → Mac | `chunk(segmentID, offset, bodyLength)` + 正文 | `offset` 必须等于 Mac 已收到的字节数 |
| iPhone → Mac | `commit(segmentID)` | 发完了 |
| Mac → iPhone | `stored(segmentID)` | 大小和 SHA-256 都对，已入库。**iPhone 只在收到这条后删除自己那份** |
| 双向 | `failure(segmentID, reason, retry)` | `retry` 为真时稍后重试（比如 Mac 关了自动回传、偏移量不对、校验失败）；为假时不要重试（比如版本不兼容、未配对） |
| iPhone → Mac | `marks([MarkInfo])` | 只在 `features` 含 `marks` 时发送，见下文 |
| Mac → iPhone | `marksStored(ids)` | 这些标记已入库，iPhone 删掉自己那份 |
| iPhone → Mac | `bye` | 正常结束 |

### 扩展与兼容

协议版本号仍是 1（老 Mac 只接受 1）。新增的消息靠 `welcome.features` 协商：

- Mac 在 `welcome` 里列出自己认识的扩展，目前有 `marks` 和 `library`。`features` 是可选字段：老 iPhone 解码时忽略它，新 iPhone 收到老 Mac 的 `welcome` 时它为空。
- iPhone 只发 Mac 列出的扩展消息。老 Mac 解不开新消息会直接断开连接，所以没列出 `marks` 时标记留在 iPhone 上，等 Mac 更新后再发；超过 60 天仍没发出去的标记丢弃。
- 新版 Mac 收到解不开、但格式正确的 JSON 头时，回 `failure(retry: false)` 并保持连接（只有 `chunk` 带正文，而每个版本都认识 `chunk`）；不是 JSON 才断开。

### 标记（`marks`）

手表上的「记下刚才」、iPhone 录音里的书签（包括手表在 iPhone 录音中按下的「记下刚才」）随录音一起转给 Mac。`MarkInfo`：

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定唯一：手表是 `watch-<会话>-<书签 UUID>`，iPhone 是 `iphone-<录音 ID>-<书签 UUID>`。同一个 ID 再发一次就是更新（比如改了标签） |
| `source` | `watch` / `iphone` |
| `recordingID` | 这个标记所属录音，和这段录音的 `SegmentInfo.recordingID` 相同 |
| `start`、`end` | 设备时钟下的真实时间；手表是会话开始时间加书签位置，iPhone 是录音开始时间加书签位置。点标记没有 `end` |
| `tag` | `todo` / `important` / `idea`，没打标签时为空 |
| `title` | iPhone 书签的名字，可为空 |

- iPhone 在手表会话摘要到达、以及自己的录音结束时把标记放进 `MacOutbox/marks/`；发完音频后按每条消息最多 100 个发出，收到 `marksStored` 再删。
- Mac 存进 `device_mark` 表，原始时间不动，另记 `clock_offset`：这段录音已有合并过的分段时用它的偏差，否则用这台设备已知的偏差；之后这段录音的分段合并时再改成那次学到的偏差。显示和总结用 `start + clock_offset`。
- 落在私人或已删除时段的标记不显示、不进总结；删除时段时一起删掉。

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

## Mac → iPhone 的对话库同步（`library`）

> 2026-11-10 实现第一版，配合 iPhone 改版（回顾 / 录音 / 搜索）。协议版本仍是 1，靠 `features` 里的 `library` 协商；老 Mac 不列出它，iPhone 就只回传、不拉取。代码：Mac 端 `Sync/Conversations.swift`、`Sync/ConversationAudio.swift`、`SyncServer`；iPhone 端 `MacLink/MacLibrary.swift`、`MacUploader`。

### 已定

| 主题 | 决定 |
| --- | --- |
| 方向 | 双向：Mac 的对话（文字和音频）同步到 iPhone；iPhone 上的删除、恢复、改名回到 Mac |
| 以谁为准 | 有 Mac 时，切段、转录以 Mac 为准；iPhone 自己的录音被 Mac 的对话包含后不再单独列出 |
| 文字 | 全部同步，iPhone 永久保留 |
| 音频 | 用 Mac 上的原始音频（16 kHz 单声道 AAC 32 kbps，约 14 MB/小时），每段对话拼成一个 M4A，不另外压缩 |
| 补齐 | 从最新往最旧，每次连接最多 30 天，`more` 为真就接着拉 |
| 归属哪一天 | 按实际时间：Mac 按天切，对话不跨 0 点 |
| 网络 | 只走局域网，和回传共用一个连接；不在 Mac 所在网络时，iPhone 显示上次同步到的内容 |
| 空间不足 | iPhone 可用空间低于 1 GB 时暂停下载音频，不自动删除，在设置里提示；文字照常同步 |

### 单位：对话

Mac 把一天的句子按时间排好，去掉私人、已删除和暂停时段里的，再切开（`ConversationRules`）：

- 两句之间安静超过 3 分钟就断开。
- 只有一两句、合计不到 12 个字的碎片（「嗯」「对」）不单独成段：10 分钟内有相邻的对话就并进去（并进更近的那个），否则不列出。
- 对话 ID 是第一句的句子 ID（`c<id>`），只要第一句还在就不变。
- 每段对话带 `digest`，包含规则版本、标题、每句的时间 / 说话人 / 文字，以及这台手机被包含进来的录音。

查看某天怎么切的：`wakeoncue conversations [日期]`。

### 消息

| 方向 | 消息 | 说明 |
| --- | --- | --- |
| iPhone → Mac | `edits([LibraryEdit])` | 待发的修改：`delete`（Mac 把这段时间标为已删除，30 天内可恢复）、`restore`、`rename`（存在 Mac 的 `conversation_title` 表）。每条有 ID，重发只生效一次 |
| Mac → iPhone | `editsStored(ids)` | 已应用 |
| iPhone → Mac | `libraryPull(bodyLength)` + 正文 | 正文是 iPhone 已有的 `[日期: digest]` JSON |
| Mac → iPhone | `libraryDay(day, bodyLength)` + 正文 | 正文是 zlib 压缩的 `LibraryDay` JSON：这一天的全部对话。iPhone 有、但这里没有的对话就删掉（Mac 上删除、标为私人或并进了别的对话） |
| Mac → iPhone | `libraryEnd(more)` | 这次发完了；`more` 为真表示还有更早的天 |
| iPhone → Mac | `audioFetch(conversationID, offset)` | 要这段对话的音频，从 `offset` 续传 |
| Mac → iPhone | `audioInfo(conversationID, digest, bytes, sha256, format)` | 整个文件的大小和 SHA-256；之后是 `audioChunk`（每块 ≤ 1 MB），最后 `audioDone`。没有音频时回 `failure(retry: false)` |

除 `chunk` 和 `audioChunk` 外，带正文的消息正文最多 16 MB。

一次连接的顺序：`hello` → `welcome` → 回传录音和标记（Mac 关了自动回传就跳过）→ `edits` → `libraryPull` 直到 `more` 为假 → 下载音频（最新的先，每次最多 30 段）→ `bye`。

### Mac 怎么判断哪天变了

每次 `libraryPull`，Mac 用 SQL 聚合给每天算一个便宜的摘要值（句子数、最小最大 ID、文字长度、时长、说话人、重转录次数），再加上当天的私人 / 删除 / 暂停时段、标题和这台手机的回传记录，一起算 SHA-256。和 iPhone 给的不同的那天才真正切段、打包。

### 音频

`ConversationAudio` 把对话时间段内的音频拼成一个 16 kHz 单声道 M4A，对话开始就是 0 秒：优先用 Mac 麦克风，Mac 没录到的地方用手表或 iPhone 的音频；私人、已删除、暂停时段和没有音频的空档写成同样长的静音，所以文字时间和音频对得上。拼好的文件缓存在 `Cache/ConversationAudio/<对话>-<digest>.m4a`，同一 digest 的文件不变，iPhone 可以续传；3 天没用的自动清掉。

### iPhone 怎么保存

- 每段对话存成一条普通录音（ID `mac_<对话 ID>`，`source = mac`），转录写进它的 `transcript.json`，音频下载到 `downloadedAudioURL`，所以回顾、搜索、问一问、对话页、播放都不用改。
- 最近 3 天新来或改过的对话，在 iPhone 上自动生成标题和总结（Apple 智能或设置里的服务）；更早的在打开时生成。
- 自己录的、已被 Mac 对话包含的录音加上 `included_in_mac_conversation`，不再单独列出，文件保留。
- 设置 › Mac 里的「Mac 的录音保存在」：「iPhone 和 Mac」（默认）自动下载音频；「只在 Mac」不下载，在 Mac 所在网络里播放时临时取。

### 还没做

- Mac 端给每段对话写标题和总结（现在由 iPhone 自己写）。
- 「只在 iPhone」：需要 Mac 在 iPhone 确认收到后删掉那段音频，而 Mac 的音频分段跨多段对话，要先能裁剪分段。
- 待办勾选的同步：现在只存在这台 iPhone 上。
- 跨好几个小时不停说话的长段落还不会再细分。
