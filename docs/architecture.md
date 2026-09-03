# WakeOnCue Recording Architecture

状态：MVP implementation；最低目标系统：iOS 18

## 1. 产品边界

WakeOnCue iOS 只负责可靠采集、持久化和同步。它不运行 ASR、Diarization、LLM 或 Agent。当前阶段通过通用 S3 SigV4 协议直连用户配置的 AWS S3 或兼容存储，不依赖 Recording API。

```text
┌──────────────────────── iPhone ────────────────────────┐
│ AVAudioEngine                                           │
│   └─ AVAudioConverter (24 kHz mono)                     │
│       ├─ source.caf (continuous PCM, local truth)       │
│       └─ 000001.m4a, 000002.m4a... (AAC upload units)   │
│                    ↓                                    │
│ SQLite: Recording + Chunk                               │
│     ├─ local mode: complete on device                   │
│     └─ S3 mode: UploadTask → Background URLSession      │
└────────────────────┬────────────────────────────────────┘
                     │ S3 SigV4 PUT
┌────────────────────▼────────────────────────────────────┐
│ User S3: metadata.json + chunks/* + source.m4a          │
└─────────────────────────────────────────────────────────┘
```

## 2. 本地音频为什么是双轨

`source.caf` 是连续的 PCM 源文件。网络不可用、上传超时或服务端宕机都不会影响它。CAF 采用 `completeUntilFirstUserAuthentication` 文件保护，使设备第一次解锁后即使再次锁屏，后台录音仍可继续写入。

上传使用单独的 AAC-LC `.m4a`：

- 24 kHz、mono、64 kbps；
- 每段目标约 10 秒；
- AVAudioEngine 不停机，Chunk 在转换后的 buffer 边界轮转，避免每 10 秒重启麦克风；
- Pause 会封口当前 Chunk，Resume 打开新 Chunk，但不创建新 Recording；
- 只有文件封口、SHA-256 计算成功并事务化写入 SQLite 后，Chunk 才会成为可恢复的本地数据；仅 S3 模式会同时创建上传任务。

PCM 源文件比只保留 Transcript 或只依赖网络流更保守。第一版暂不自动清理本地音频。

Finish 时使用 AVFoundation 把所有 AAC Chunk 合成为标准 AAC-LC `.m4a`。同一个文件用于本地播放、系统分享和 S3 的 `source.m4a`；CAF 继续作为更保守的本地源文件，不直接分享。

## 3. 状态模型

Recording 状态：

```text
READY → RECORDING ↔ PAUSED → FINISHING → UPLOADING → COMPLETED
                  ↘                      ↘
                    FAILED ←──────────────
```

`READY` 表示当前没有 Recording。数据库中的新记录直接从 `RECORDING` 开始。

Chunk 状态：

```text
pending → uploading → uploaded
             ↓          ↑
           failed ──────┘
```

UploadTask 类型：

- `createRecording` → S3 `metadata.json`
- `uploadChunk` → S3 `chunks/000001.m4a...`
- `finish` → S3 `source.m4a`

metadata 上传成功前不上传 Chunk。完整 `source.m4a` 只有在 metadata 和全部 Chunk 都收到 S3 2xx 后才上传；最终文件收到 S3 2xx 后 Recording 才进入 COMPLETED。Pause / Resume 只改变本机状态，不额外产生云端请求。

本地模式不创建 UploadTask。Finish 会合并 M4A，并在本机事务中直接把 Recording 和 Chunk 标记为完成。对于 S3 模式，完成等待期间也提供“Save to this iPhone”作为保留真实本地文件的退出路径。

## 4. SQLite 事务边界

SQLite 使用 WAL、foreign keys 和 `synchronous=FULL`。

### Recording

包含全局唯一 ID、创建/开始/结束时间、时长、状态、本地源文件路径、上传汇总、设备与版本、metadata。

### Chunk

包含 `recording_id + chunk_index` 唯一约束、本地路径、SHA-256、字节数、开始时间、时长、状态和错误。

### UploadTask

包含任务类型、去重键、文件路径、状态、retry count、next retry、错误和 Background URLSession task identifier。

插入 Chunk、增加 pending count、更新持久化时长和创建 UploadTask 在同一事务内完成。收到 S3 2xx 后，UploadTask、Chunk、uploaded bytes 和 pending count 也在同一事务内更新。

开始一个 Chunk 上传时，UploadTask 与对应 Chunk 会在同一事务内进入 `uploading`。每个请求包含实际文件的 SHA-256，并使用 AWS Signature Version 4 对 host、路径、时间、内容类型和 payload hash 签名；只有 S3 成功响应才确认任务。

## 5. 后台上传和恢复

后台 session 使用固定 identifier，并且所有 upload task 都来自文件。App 启动时先重新创建同一 session，读取系统仍在管理的 tasks，再重置已经没有系统任务对应的 `uploading` 行，避免正常后台任务被误判为孤儿。

网络行为：

- `waitsForConnectivity = true`；
- Wi-Fi / Cellular 均允许；
- NWPath 恢复时重新调度；
- HTTP / 网络失败持久化错误并指数退避，最大 15 分钟；
- 每个 Recording 使用稳定 object key，重复 PUT 覆盖同一对象，不创建重复 Chunk。

如果 App 在录音时被终止，iOS 不可能继续运行普通麦克风进程。下次启动会：

1. 把 Recording 从 RECORDING / PAUSED 置为 FINISHING，并重新接管已进入 FINISHING 但尚未完整入队的窗口；
2. 保留系统仍管理的 Background URLSession tasks；
3. 重置孤儿 uploading tasks；
4. 扫描未入库但仍可由 AVFoundation 读取的 `.m4a` 并补入队列；
5. 合并 M4A，上传全部可恢复 Chunk 和最终 `source.m4a`；
6. 连续本地 `source.caf` 始终保留供人工恢复或未来重切 Chunk。

未配置 S3 时，恢复扫描仍会补录可读的 `.m4a`，但不会启动 Background URLSession；中断或旧版本卡在 FINISHING / UPLOADING 的 Recording 会直接在本机完成并解除操作锁。

## 6. 系统入口

- App 首页：直接调用同一个 AppModel 状态机；
- App Shortcuts / Action Button：`AudioRecordingIntent`；
- iOS 18 Control：WidgetKit `ControlWidget`；同一 Control 可放到 Control Center、锁屏和支持的 Action Button；
- Live Activity：录音开始时创建并提供 Pause / Resume / Finish。本地模式只显示本机保存状态，不出现上传提示；配置 S3 后才显示已同步时长和等待同步时长。

App 内状态变化会通过 `ControlCenter.reloadControls` 刷新系统 Control。Finish 后 Live Activity 切换为上传状态并固定已录时长，不再显示麦克风仍在录音。

Apple 要求 AudioRecordingIntent 开始录音时同时保持 Live Activity，本实现先创建 Activity 再投递录音命令。锁屏首次启动录音的权限和音频 session 行为仍必须在目标 iOS 版本、真实签名和真机上验证。

## 7. S3 配置边界

Bucket、Region、Endpoint、Prefix 和 path-style 保存在 UserDefaults；Access Key、Secret Key 和可选 Session Token 保存在 iOS Keychain。点击 Save 时，App 使用候选配置执行临时对象 PUT、HEAD、DELETE，全部成功后才替换当前生效配置。

Recording API 和 Agent/Webhook 当前不参与链路。后续需要 Agent 时，应以 S3 中已经确认完成的 `source.m4a` 为数据源，再增加事件或 API 层，不能让 Agent 成为录音完成的依赖。

## 8. 实时处理旁路

启用实时文字后，AVAudioEngine 转换后的同一份 24 kHz mono PCM 还会按 0.5 秒复制给 Realtime Client。文件写入和 Chunk 封口仍先执行；Realtime Client 使用独立 actor 和 WebSocket 发送，不参与 Recording / Chunk / UploadTask 状态机。

App 只依赖版本化 Gateway。Gateway 负责短期会话、Processor 路由、revision 和断线事件补放，不运行模型。当前 Mac Processor 是协议的第一个实现，未来可换成云端 Processor，而无需更新 iOS 音频或字幕协议。完整说明见 [Realtime Processing](realtime-processing.md)。

实时链路断开时最多缓存约 60 秒待发送 PCM；超过上限只丢弃最旧的实时帧，不删除本地 CAF/M4A。Processor 不可用时 Gateway 不持久化音频，最终可通过 S3 `source.m4a` 做补处理，避免为实时功能引入另一套录音事实来源。

Mac Processor 的 ASR 使用约 4 秒窗口。说话人分析默认使用约 30 秒的有限滚动窗口（20 秒推进、10 秒重叠），不随整场会议时长重复计算所有历史音频；每个模型临时 speaker label 会计算 embedding，并与会话内稳定 cluster centroid 匹配。因此后续窗口即使交换模型标签，App 中的 Speaker 1/2 仍可保持一致。字幕先以 Unknown speaker 出现，再用同一 segment ID 的 `speaker.corrected` 事件修订。

## 9. 已知边界

- 第一版没有账户注册、多租户或 Agent 事件；
- 用户需要提供权限受限的 S3 凭据；
- 自动清理故意未启用；
- 本机 M4A 合并依赖 AVFoundation；
- 录音中的 Force Quit 会停止麦克风，这是 iOS 进程语义；已完成 Chunk 与系统后台上传任务会在重开后恢复；
- 完整 Xcode build、锁屏 30 分钟、断网 10 分钟和 60 分钟录音只能由真机验收。
- Speaker 1/2 是会话内声纹聚类，不是人员真实姓名；姓名需要后续 enrollment 或用户确认。
