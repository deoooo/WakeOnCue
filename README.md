# WakeOnCue

WakeOnCue 是一个独立的 Native iOS 会议录音 MVP，录音只保存在你的设备上。它不依赖 Omi，转写和摘要默认在 iPhone 本机完成，也可以换成你自己配置的第三方服务。

```text
iPhone microphone
  → continuous local PCM source (Source of Truth)
  → 10-second AAC chunks
  → local completion
```

可靠性优先级是：本地录音 > 不丢数据 > 交互 > 视觉效果。网络和服务端不参与麦克风到本地文件的写入路径。

现在也提供可选的实时分析旁路：iPhone 把 0.5 秒 PCM 帧发送到稳定 Realtime Gateway，由可替换 Processor 返回带说话人字段和 revision 的实时字幕。Gateway/Processor 故障不会影响本地录音；Mac 只是当前首个 Processor 运行环境，App 协议不依赖 Mac。

完成时 App 把 Chunk 合成为兼容性广、体积较小的 AAC-LC `.m4a`，用于本地播放和系统分享。

iPhone 不再上传到 S3。旧版本已备份到 S3 的录音，仍可用这台 iPhone 上保存的凭据按需下载，也可以在设置里移除凭据。Recording API 暂不参与 App 链路，保留的服务端代码仅供后续 Agent/API 阶段重新接入。

## 当前实现

- iOS 18、SwiftUI、AVAudioEngine / AVAudioConverter；
- 连续 `24 kHz / mono / 16-bit PCM CAF` 本地源文件；
- 约 10 秒一个 `64 kbps AAC-LC .m4a` Chunk；
- `Recording / Chunk / UploadTask` 三表 SQLite（WAL + FULL synchronous）；
- Start / Pause / Resume / Finish 保持同一 `recording_id`；
- Live Activity、App Shortcuts、iOS 18 Control Center / Lock Screen Control、可选 Action Button；
- 本机合并并分享标准 AAC-LC M4A；
- 本地完成后即可开始下一场；录音中展示真实收音电平、输入设备和中断状态；
- Apple Watch：查看与遥控 iPhone 录音；iPhone 开不了时由手表全程录音（60 秒分段同步到 iPhone 合成）；录音中「记下刚才」标记最近 2 分钟并打待办/重要/想法标签；表盘复杂功能；
- 完整录音库、持久化命名、本地字幕搜索、重点标记及 TXT/SRT 导出；
- 区分说话人（默认关闭）：匿名的说话人 1 / 2，可按录音命名或从通讯录选择；登记本人声音后标为「我」；可选「记住声音」自动认出已命名的人，声纹只存在 iPhone Keychain，一年未出现自动删除；
- iOS 26+ 设备端免费转写（SpeechAnalyzer）与摘要（Apple 智能），没有实时服务也能用；支持 AirPods 高质量录音和导入音频文件；
- 可选第三方服务：转写接入 OpenAI 兼容的 `/audio/transcriptions`，摘要和提问接入 OpenAI 兼容 API 或 Claude API，见[说明](docs/ai-providers.md)；
- 地点：到达或离开设定地点时结束录音，到达时提醒一键开始（iOS 不允许后台自动打开麦克风）；
- 日历（默认关闭）：会议期间开始的录音自动用会议名命名并记下参会人；可在会议开始时（或提前 N 分钟）收到提醒，一键开始录音；可限定日历、只算有其他参会人或视频链接的会议；会后在录音详情页把摘要、要点和待办整理成纪要，经邮件或分享面板发给参会人（由你确认发送）；
- 系统自适应浅深色、大字体布局；实时服务支持二维码或粘贴配对、连接测试与验证后保存；
- 可选 Realtime Gateway、断线重连/事件补放和 App 内实时字幕；
- macOS 菜单栏 App（v1）：一键启停本机 Gateway 与 Mac Processor、显示运行状态、iPhone 配对二维码、登录时打开；线上会议（Zoom、Teams、飞书）同时录麦克风（我）和系统声音（对方），先写本地文件，再作为两个声道会话实时转写，小窗口显示实时文字；
- 可替换 Mac Processor：Qwen3-ASR-1.7B 实时初稿/原位修订（MLX Whisper 回退）+ sherpa-onnx 说话人分割、会话内聚类与已保存声音匹配；
- Swift 核心单元测试和真实 AAC/M4A 验证。

详细说明：

- [系统架构](docs/architecture.md)
- [Recording API Contract](docs/api-contract.md)
- [本地开发与真机启动](docs/development.md)
- [MVP 范围与验收](docs/mvp.md)
- [验证结果](docs/verification.md)
- [录音体验改进与验证范围](docs/product-experience.md)
- [实时处理协议与部署](docs/realtime-processing.md)
- [提问与 MCP](docs/mcp.md)
- [第三方语音识别与 AI 服务](docs/ai-providers.md)
- [Apple Watch 接入](docs/apple-watch.md)

想在自己的 MacBook 上直接跑实时服务，可从仓库根目录执行
`server/scripts/setup_mac.sh` 后运行 `server/scripts/run_local_mac_stack.sh`；连接
iPhone 后运行 `ios/install_device.sh <device-id-or-udid>` 完成构建和安装。首次使用只需
在 Xcode 选择自己的 Development Team，并在 iPhone 上允许麦克风和本地网络访问。

## Mac 菜单栏 App

`ios/project.yml` 里的 `WakeOnCueMac` target（代码在 `ios/WakeOnCueMac/`，macOS 15+）是一个只在菜单栏显示的 App：

- **实时服务**：启动或停止本机 Python Gateway（端口 8090，所有网卡）和 Mac Processor，与 `run_local_mac_stack.sh` 相同；用 Bonjour 广播 `_wakeoncue._tcp`，通过 `/health` 显示 Gateway 是否在线、Processor 是否已注册。Gateway 令牌沿用钥匙串里 `setup_mac.sh` 创建的那一项，没有时自动生成。终端里已经启动的 Gateway 也会被识别，只监控不接管。
- **配对 iPhone**：点「配对 iPhone…」后手动显示二维码（内容与 `generate_realtime_pairing.py` 相同，包含令牌，不落盘）。
- **登录时打开**（`SMAppService`）与「打开 App 时启动实时服务」两个开关。
- **录制线上会议**：麦克风标为「我」，Core Audio process tap 抓到的系统声音标为「对方」，不需要声纹。两路先写入 `~/Library/Application Support/WakeOnCue/Meetings/<recording_id>/microphone.caf` 与 `system.caf`，停止后合成 `meeting.m4a` 并保存 `transcript.json`；实时服务不可用时只录本地。可选「区分对方说话人」（默认关闭，匿名说话人 1 / 2，不保存声纹）。
- v1 不内置 Python：App 在自己所在的代码目录（及其上级，git worktree 会复用主 checkout 的 `.venv`）或用户选择的文件夹里寻找 `server/.venv`、`.runtime/asr-qwen/.venv`，缺失时提示运行 `server/scripts/setup_mac.sh`。日志在 `server/.runtime/mac-app/`。

```bash
cd ios
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCueMac -destination 'platform=macOS' build
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCueMac -destination 'platform=macOS' test
```

单元测试覆盖配对二维码（生成后再解码）、分帧与写盘、混音导出和双声道字幕合并。另有两个默认跳过的集成测试：`~/Library/Caches/com.deoooo.WakeOnCue.mac.e2e.json`（`{"gateway": "...", "token": "..."}`）存在时把两个声道流到真实 Gateway；`~/Library/Caches/com.deoooo.WakeOnCue.mac.host-e2e` 存在时用本机 Python 环境真实启停整套服务。

首次录音时 macOS 会分别请求麦克风和「录屏与系统录音」（系统声音）权限。

## 打开 iOS 工程

仓库包含可直接打开的 [WakeOnCue.xcodeproj](ios/WakeOnCue.xcodeproj/project.pbxproj)。需要安装带 iOS 18+ SDK 的完整 Xcode：

```bash
open ios/WakeOnCue.xcodeproj
```

在 Xcode 中设置自己的 Development Team，并为 App 与 Widget Extension 配置同一个 App Group。默认标识为 `group.com.deoooo.WakeOnCue`；若修改，请同步修改 `ios/project.yml`、两个 entitlements 和 `SharedRecordingState.appGroup`，再运行：

```bash
cd ios
xcodegen generate
```

第一次请从 App 内授权麦克风并成功开始一次录音，再配置 Control Center、锁屏 Control 或 Action Button。

## 可在 macOS 命令行执行的测试

```bash
cd ios/Packages/WakeOnCueCore
swift test

cd ../../../..
PYTHONPATH=server python3 -m unittest discover -s server/tests -v
```

完整 Xcode 构建和真机可靠性步骤见 [开发说明](docs/development.md)。当前仓库不会把命令行 Swift 测试、fixture 或服务端合成音频测试描述成 iPhone 真机录音证明。

## 许可

WakeOnCue 按组件分别授权，详见 [LICENSE](LICENSE)：

- `ios/`（iOS、watchOS、小组件与 WakeOnCueCore）：[AGPL-3.0-only](ios/LICENSE)
- `server/`（Gateway、Processor、Recording API）及其余文件：[Apache-2.0](server/LICENSE)

「WakeOnCue」名称与图标不随代码授权，发布修改版请更换名称和图标，见 [TRADEMARKS.md](TRADEMARKS.md)。贡献代码前请签署 [CLA](CLA.md)，流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。commit `ffaf4b3` 及之前的版本仍按 MIT 协议提供。
