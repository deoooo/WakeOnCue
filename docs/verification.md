# Verification Report

更新时间：2026-08-27

## Latest LAN direct validation (2026-08-31)

The signed iPhone Air build was installed after the LAN transport fix and started with
the debug recording command. Recording `rec_71f3e7363b9b497cbbf7361ea2cc68c4` created its
realtime session and WebSocket through `http://DeoMacBook-Pro.local:8091`; the configured
Cloudflare Quick Tunnel was not used. The LAN Gateway health response reported
`processors_available=1`, and the Qwen3-ASR processor remained running. The 25.8-second
recording finished with `COMPLETED`, `upload_status=COMPLETED`, `pending_chunks=0`, a
102 KB local M4A, and a persisted `transcript.json`. This validates the physical-device
LAN route and S3 completion; this particular silent synthetic test has an empty
transcript by design and is not an accuracy sample.

环境：macOS 26.5.1 arm64、Xcode 26.6 (17F113)、iOS 26.5 Simulator (23F77)、iPhone 17 Pro / iPhone Air Simulator、iPhone Air `iPhone18,4`（iOS 26.3）实体机、Python 3.13.0、ffmpeg 8.1、XcodeGen 2.46.0。

## Realtime Processing 第一阶段

| Check | Result | Evidence |
|---|---|---|
| Protocol models | PASS | Swift `RealtimeContractTests` 2/2；v1 wire keys、PCM format、speaker 和 revision 解码通过 |
| Gateway routing/replay | PASS | Python Gateway tests 3/3；鉴权、Processor 注册、音频路由、revision、replay、Processor 晚到后的 Finish 补投通过 |
| Existing Recording API regression | PASS | Python 全套 15/15；原有 Recording/S3、Gateway、Mac Processor 与 speaker tracker 同时通过 |
| iOS build | PASS | iOS Simulator generic build `BUILD SUCCEEDED`；App、Widget、Core 全部编译通过 |
| iOS tests | PASS | iPhone Air Simulator `WakeOnCueTests` 10/10；Core 全套 21/21 |
| App launch/layout regression | PASS（Simulator） | 新构建安装到已启动的 iPhone Air Simulator，首页、历史录音与中文布局正常显示 |
| Real ASR pipeline smoke | PASS（public synthetic scope） | macOS `say` 仅写文件、不播放；合成中文经公网 HTTPS/WSS Gateway → Mac MLX `whisper-large-v3-turbo` → 1 个完整中文 `transcript.upsert` → `session.completed`，文字与原句一致 |
| Qwen realtime revision | PASS（local Gateway + real file scope） | 最新 106.6 秒 M4A 仅以文件方式模拟 0.5 秒 PCM 帧；Qwen3-ASR-1.7B/MPS 在 35.3 秒内产生 41 次初稿/修订并归并为 14 个稳定 segment。另以当前运行中的 Gateway 发送前 8 秒，收到 5 次同 ID upsert 和 `session.completed`，确认实际路由已切到 Qwen；未播放音频。 |
| ASR rolling context and language | PASS（unit + runtime） | 16 秒窗口 / 4 秒步进、词级边界去重、会话语言锁定、最近文本 prompt、静音与重复幻觉过滤通过单测；设置中的讲话语言独立于界面语言并同时作用于实时录音和重新转写 |
| Long live Chinese smoke | PASS（public synthetic scope） | 23.8 秒连续中文在 `session.finish` 前返回实时文字，最终 7 段并正常完成；无混合脚本乱码或重复幻觉，语义完整，合成原句中的“周五”漏识别一个“周” |
| Speaker diarization | PASS（official fixture + rolling pipeline scope） | sherpa-onnx 官方四人中文样本经默认 30 秒滚动窗口跑完整 Gateway + MLX ASR：20 条 transcript、21 条 speaker correction、仅 `speaker_1...4`、revision 1...41 连续、session completed |
| Physical iPhone live transcript | DEVICE NOT RUN | 尚未将 Gateway/Processor 暴露为真机可访问的 HTTPS/WSS 地址，也未跑真实多人录音 |

## 当前执行结果

| Check | Result | Evidence |
|---|---|---|
| Xcode + iOS Simulator installation | PASS | 官方 Mac App Store Xcode 26.6；Apple SDK agreement 已接受；iOS 26.5 Simulator 8.52 GB 已安装 |
| Signed iOS build | PASS | iPhone 17 Pro Simulator 目标，`Sign to Run Locally`，App + Widget Extension 完整构建；`BUILD SUCCEEDED`，0 warning |
| Xcode Simulator tests | PASS | `RecordingFileLayoutTests` 2/2 passed；`TEST SUCCEEDED` |
| Swift core build + tests | PASS | `swift test`，17/17 passed；包含 S3 object key、流式 SHA-256、SigV4 和真实兼容端点 round-trip |
| SQLite state / queue recovery | PASS | 创建依赖、原子 claim、活跃/孤儿后台 task、FINISHING 窗口、retry gate、重启后下一次 retry 唤醒、容器路径重定位、Pause/Resume 顺序和 Finish gate 均通过 |
| Stuck local completion recovery | PASS（unit + Simulator） | 云端不可用时，旧 FINISHING/UPLOADING 录音覆盖安装后自动变为 COMPLETED；活动录音计数为 0，pending_chunks=0，界面回到 READY 且音频保留在最近录音 |
| Time-based sync progress | PASS（unit + Simulator） | Core 直接按 Chunk duration 汇总 uploaded/pending；iPhone Air Simulator 录音中显示 Synced `00:00:20`、Waiting `00:00:05` |
| Local-only presentation | PASS（Simulator） | 未配置 S3 时 Ready、Recording、Finishing、历史录音均只显示 Saved locally / Finalizing，没有 Uploading、Synced、Waiting 或 chunk 文案 |
| Local playback | PASS（Simulator） | 完成录音的 Play 按钮启动后无障碍状态切换为 Pause recording，证明本地 AVAudioPlayer 进入播放态 |
| Real-file sharing | PASS（Simulator） | 系统分享面板收到并展示本地 `.m4a` 文件、音频类型和文件大小；activity item 不是 URL 文本 |
| Direct optional S3 configuration | PASS（local integration scope） | App 已移除 Recording API 配置；凭据进入 iOS Keychain；Save 执行 PUT→HEAD→DELETE。隔离 MinIO 真实 SigV4 round-trip 通过，临时对象已删除 |
| Direct S3 upload contract | PASS（unit + local integration） | metadata、稳定 Chunk key、最终 `source.m4a`；文件流式 SHA-256、SigV4 Authorization、自定义 endpoint/path-style 均通过 |
| Local M4A assembly | PASS（runtime） | 用 Simulator 真实录音的两个 AAC Chunk 运行 AVFoundation 合并；输出 AAC-LC、24 kHz mono、13.013s、53,371 bytes，ffprobe 可读取 |
| Simulator app launch/UI | PASS | App 安装并真实启动；麦克风授权页、Ready、Recording、Paused、Uploading、Completed 状态均由 Simulator accessibility tree 与截图确认 |
| Simulator audio capture | PASS（Simulator scope） | 本地 `source.caf` 为 PCM s16le / 24 kHz / mono / 40.997s；首个 Chunk 为 AAC / 24 kHz / mono / 10.197s；这是模拟器音频，不是真机麦克风质量证明 |
| Simulator background upload E2E | HISTORICAL（old API path） | 旧 App→Recording API 链路曾完成；不能作为当前 App→S3 真机证明。当前直连 S3 已完成 Core/MinIO round-trip，仍需用户真实 Bucket 做 App E2E |
| Pause / Resume E2E | PASS（Simulator scope） | 第二条录音暂停后 4 秒内计时保持 22 秒，恢复后继续录制并完成上传 |
| Dynamic Island / Lock Screen Live Activity | PASS（Simulator scope） | Dynamic Island 显示红色录音图标和计时；锁屏卡片实跑 Pause→Resume→Finish，状态恢复更新缺陷修复后显示 `Recording uploaded`、pending=0 |
| App update/container recovery | PASS（Simulator scope） | 覆盖安装导致容器 UUID 变化后，持久化路径自动重定位，6 个待传 Chunk 恢复上传并完成；新增 Core 回归测试 |
| Merged/shareable audio | PASS（Simulator/runtime scope） | 完成文件使用标准 `.m4a`；AVFoundation 合并输出为 AAC / 24 kHz / mono，播放与真实文件分享路径不再依赖 API |
| Plist / entitlements / icon | PASS | plist/entitlements lint 通过；App icon 为 1024×1024 PNG |
| Physical iPhone signing/run | PASS | USB iPhone Air、Developer Mode、Personal Team、App + Widget + App Group 自动签名；真机 build/install/launch 均通过 |
| Physical iPhone audio capture | PASS（短时样本） | 真机 `rec_616d04dc15e6413a80c2c0843a80f927`：Start→16 个连续 Chunk→Finish；AAC 非静音。该样本的旧 API 上传结果不作为当前直连 S3 证明 |
| iPhone Air full-screen layout | PASS | 补齐 `UILaunchScreen` 后消除兼容模式上下黑边；同型号 Simulator 截图确认 Dynamic Island、安全区、首屏按钮和指标无裁切，真机覆盖安装启动通过 |

## Simulator 端到端样本

| Recording | Flow | Client result | Server result |
|---|---|---|---|
| `rec_fb688eef09a649cfbbd3f3c124f5ac73` | 连续录音 + 覆盖安装/容器迁移恢复 | 6 chunks，最终 Completed | `COMPLETED`，60.086s，673,179 uploaded bytes，audio available |
| `rec_7021ff674a1c4fe9a685a8ab83dc0a45` | Recording → Pause → Resume → Finish | 暂停计时冻结，5 chunks，最终 Completed | `COMPLETED`，40.997s，489,046 uploaded bytes，audio available |
| `rec_94fcf4eecce44753aad457b8eb3bb8f2` | Dynamic Island + 锁屏 Live Activity Pause/Resume/Finish | 锁屏控制与状态回推通过，8 chunks | `COMPLETED`，71.486s，832,707 uploaded bytes，pending=0 |

## Physical iPhone 端到端样本

| Recording | Flow | Client result | Server / media result |
|---|---|---|---|
| `rec_616d04dc15e6413a80c2c0843a80f927` | USB 自动触发 Start → 真实麦克风录音 → 用户 Finish | 155.796s，16 chunks，最后 pending=0 | `COMPLETED`；1,762,387 uploaded bytes；AAC 24 kHz mono；合并音频 157.525s / 1,253,679 bytes；mean -42.1 dB、max -18.2 dB；Chunk 1...16 连续 |

真机第一次 Start 返回 `NSOSStatusErrorDomain -50`。分阶段诊断将失败精确定位到 `AVAudioSession.setCategory(.record, mode: .spokenAudio, ...)`；`spokenAudio` 是连续语音播放模式。改为所有 category 均支持的 `.default` 后，同一实体机 Start、Chunk 生成、Background URLSession 上传、Finish、服务端合并和下载全部通过。

第一次安装时曾使用 `CODE_SIGNING_ALLOWED=NO`，Simulator 的后台传输守护进程因此拒绝创建 background upload task（NSCocoaError 4097）。改用 Xcode 的 `Sign to Run Locally` 后后台会话建立成功。此失败被保留为测试环境诊断证据，不属于产品网络失败。

## 原始目标逐项审计

下表区分 Simulator、本地后端与实体机证据；Simulator PASS 不能替代真机 PASS。

| Requirement | Current result | Authoritative evidence / remaining boundary |
|---|---|---|
| Native Swift / SwiftUI，最低 iOS 18 | PASS（build scope） | deployment target 18.0；Xcode 26.6 完整构建无 warning |
| 本地录音是 Source of Truth | PASS（Simulator + short physical scope） | 连续 PCM 与独立 AAC Chunk 已实产；真机 16 个 Chunk 连续并合并为非静音音频 |
| 同一 recording ID 的 Start/Pause/Resume/Finish | PASS（Simulator + backend scope）/ PHYSICAL PARTIAL | Simulator 跑过 Pause/Resume；真机同一 ID 跑过 Start/Finish，真机 Pause/Resume 尚未执行 |
| 约 10 秒 AAC mono Chunk、Checksum、S3 确认 | PASS（Simulator + short physical + integration scope） | 真机已生成 16 个连续 24 kHz mono AAC Chunk；稳定 S3 key、文件 SHA-256 与真实 SigV4 PUT/HEAD/DELETE 通过 |
| Recording / Chunk / UploadTask 持久化队列 | PASS | SQLite 事务、依赖、retry、ACK、进程/容器迁移恢复测试通过 |
| 断网恢复与 Background URLSession | PARTIAL PASS / DEVICE NOT RUN | Simulator 系统 background session、失败退避、重启/升级恢复已验证；Wi-Fi/Cellular 切换与真机系统调度未跑 |
| App 首页入口 | PASS（Simulator + physical scope） | 真机安装、启动、Start、Finish 和状态交互实跑；iPhone Air 全屏兼容问题已修复 |
| Control Center / Lock Screen / optional Action Button | PARTIAL PASS / DEVICE NOT RUN | 锁屏 Live Activity 的 AudioRecordingIntent Pause/Resume/Finish 已在 Simulator 实跑；Control Center、锁屏 Control 和 Action Button 仍需实体机 |
| Live Activity | PASS（Simulator scope）/ DEVICE NOT RUN | Dynamic Island 与锁屏卡片计时、Pause/Resume/Finish/Completed 已实跑；实体机长时持续性未跑 |
| App→S3 metadata/Chunk/final M4A | PARTIAL PASS / REAL BUCKET NOT RUN | object contract、SigV4 和隔离 MinIO round-trip 通过；用户真实 Bucket 的完整 App E2E 尚未执行 |
| Recording API / Agent event | DEFERRED | 已按当前产品决定移出 App 配置和第一阶段链路；旧服务端实现保留供后续恢复 |
| iOS 不耦合 ASR / Agent / AI provider | PASS（source audit） | iOS target 无 ASR、LLM 或 AI provider；S3 使用通用 SigV4，不引入厂商 SDK |
| README / Architecture / API / Development / verified-unverified 清单 | PASS | 仓库内交付物与当前结果同步 |
| 7 项第一阶段验收 | INCOMPLETE（physical-device boundary） | 本地/Simulator 范围已完成；依赖真实锁屏、网络切换、长时录音和系统入口的 Case 保持未执行 |

## 仅剩实体机才能完成的验证

- 更长真机样本的主观音质与本地 PCM/最终 M4A 缺口检查（短时非静音样本已通过）；
- 60 分钟连续录音稳定性；
- 锁屏 30 分钟、切后台使用其他 App、音频 interruption 与 route change；
- Wi-Fi/Cellular 切换、离线 10 分钟与 Background URLSession 真机系统调度；
- Control Center、锁屏 Control、Action Button、App Intent 首次/重复启动；
- Live Activity 在真机锁屏和 Dynamic Island 的长时持续更新与系统节流表现；
- 真机 Force Quit/relaunch 后已封口 Chunk 与系统后台 task 重新关联；
- Personal Team 7 天签名到期后的重新签名/安装操作（当前签名、App Group provisioning 与安装已通过）。

这些项目按 [development.md](development.md) 的真机矩阵执行。在实体机证据产生前保持 `DEVICE NOT RUN`，不能用 Simulator 结果替代。
