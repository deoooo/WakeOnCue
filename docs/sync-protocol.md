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

- Mac 在 `welcome` 里列出自己认识的扩展，目前只有 `marks`。`features` 是可选字段：老 iPhone 解码时忽略它，新 iPhone 收到老 Mac 的 `welcome` 时它为空。
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

## Mac → iPhone 的对话库同步（设计中，未实现）

> 2026-11-10 定的方向，配合 iPhone 改版（回顾 / 录音 / 搜索）。仍是协议第 1 版，靠 `features` 里的 `library` 协商；老 Mac 不列出它，iPhone 就只回传、不拉取。

### 已定

| 主题 | 决定 |
| --- | --- |
| 方向 | 双向：Mac 的录音、转录、总结同步到 iPhone；两边的修改互相同步 |
| 以谁为准 | 有 Mac 时，合并后的时间线、切段、最终转录和总结以 Mac 为准；iPhone 本机先出的结果在 Mac 版到达后静默替换。没有 Mac 时 iPhone 自己就是全部 |
| 文字 | 全部同步，iPhone 永久保留 |
| 音频 | 同步，用 Mac 上的原文件（16 kHz 单声道 AAC 32 kbps，约 14 MB/小时），不另外压缩。默认两边都永久保留，可在 iPhone 设置里改保存位置，见下文 |
| 归属哪一天 | 按实际时间。对话跨过 0 点时在 0 点切开，前半段归前一天，后半段归后一天 |
| 补齐 | 配对后从最新往最旧自动补，不设起始范围；新内容优先于补旧 |
| 网络 | 只走局域网，和回传共用同一个连接。离开 Mac 所在网络时，iPhone 显示上次同步到的内容 |
| 空间不足 | iPhone 可用空间不足时暂停下载音频，不自动删除；在设置里提示还差多少、已暂停多少，文字照常同步 |

### 录音保存位置

iPhone 设置 › 设备 下的「录音保存在」，只在配对后出现。只管音频；文字总是两边都有。

| 选项 | iPhone | Mac |
| --- | --- | --- |
| iPhone 和 Mac（默认） | 自己的录音回传后保留原文件；Mac 的音频全部下载 | 全部保留 |
| 只在 Mac | 自己的录音回传、Mac 确认后删除（现在的做法）；不下载 Mac 的音频，播放时连上 Mac 临时取，离开局域网不能播放 | 全部保留 |
| 只在 iPhone | 自己的录音照常回传给 Mac 转录合并；Mac 的音频全部下载 | iPhone 确认收到（`audioDone` 后回 `audioKept`）才删除那段音频，只留文字。之后 Mac 上不能回放、不能重新转录这段 |

- 这个选项存在 Mac 上，按设备记：Mac 在 `welcome` 里带回当前值，iPhone 改了就发 `storagePreference`。多台 iPhone 时，只要有一台选了「只在 iPhone」，Mac 就在那一台确认收到后删除；其他 iPhone 之后也就取不到这段音频。
- 从「只在 iPhone」改回其他选项时，Mac 已删的音频不会回来；从「只在 Mac」改回默认时，iPhone 开始从新往旧下载。
- Mac 自己的「音频保留期限」（7 天 / 30 天 / 永久）照旧生效，和这个选项取更早删除的那个。
- 空间不足的规则对两种需要下载的选项都适用。

### 单位：对话

iPhone 按「一段对话」展示，不按小时。对话由 Mac 切分：同一时间线上连续 3 分钟以上没人说话就断开（阈值待调）。每段有稳定的 `id`、起止时间、来源、标题、摘要、要点（带句子引用）、待办和逐句原文。每小时总结和当天总结仍是 Mac 自己的界面，按需另外下发。

切段、每段标题和摘要在 Mac 上都是新功能。

### 消息（草案）

| 方向 | 消息 | 说明 |
| --- | --- | --- |
| iPhone → Mac | `libraryPull(cursor, limit)` | 要 `cursor` 之后的变化；`cursor` 为空表示从头开始，Mac 先给最新的 |
| Mac → iPhone | `libraryChanges(conversations, deleted, cursor, more)` | `conversations` 是新增或改过的对话（完整内容，按 `revision` 覆盖）；`deleted` 是删除或标为私人的对话 ID；`more` 为真时继续拉 |
| iPhone → Mac | `audioFetch(partID, offset)` | 要一个音频分段，断了从 `offset` 续 |
| Mac → iPhone | `audioChunk(partID, offset, bodyLength)` + 正文 | 和回传的 `chunk` 对称，每块 ≤ 1 MB |
| Mac → iPhone | `audioDone(partID, sha256)` | 发完，iPhone 校验后入库 |
| iPhone → Mac | `audioKept(partIDs)` | 这些分段已存好；保存位置是「只在 iPhone」时 Mac 收到后删除 |
| iPhone → Mac | `storagePreference(value)` | 改了录音保存位置 |
| iPhone → Mac | `edits([EditInfo])` | iPhone 上的修改：改标题、说话人命名、勾待办、删除对话 |
| Mac → iPhone | `editsStored(ids)` | 已应用，iPhone 删掉待发的修改 |

对话里的 `audio` 列出它覆盖的音频分段（`partID`、开始时间、时长、字节数、SHA-256）。私人和已删除时段 Mac 先剪掉再发，不下发原段。来自这台 iPhone 的分段带上原来的 `SegmentInfo.id`，iPhone 本地还有这份音频时就不再下载。

### 修改和冲突

- 每个可改字段带修改时间，后改的为准。两边同时改同一字段的情况少，不做合并。
- 删除用墓碑：`deleted` 里的 ID 保留 60 天，避免删掉的对话被旧数据带回来。现有的 `drop` 时段照旧，防止 iPhone 把已删除时段的音频再传给 Mac。
- iPhone 离线时的修改放进本地队列，和回传的 `MacOutbox` 一样，连上后先发修改再拉变化。

### 顺序

一次连接里：`hello` → `welcome` → 回传录音和标记 → 发修改 → 拉对话变化 → 下载音频（先新后旧）→ `bye`。音频下载可以随时中断，下次接着来。

### 待定

- 切段阈值。
