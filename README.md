# WakeOnCue

WakeOnCue 是一个原生的 iPhone、Apple Watch 和 Mac 录音 App，录音只保存在你的设备上。它不依赖 Omi，转写和摘要默认在 iPhone 本机完成，也可以换成你自己配置的第三方服务。

```text
iPhone microphone
  → continuous local PCM source (Source of Truth)
  → 10-second AAC chunks
  → local completion
```

可靠性优先级是：本地录音 > 不丢数据 > 交互 > 视觉效果。网络和服务端不参与麦克风到本地文件的写入路径。

完成时 App 把 Chunk 合成为兼容性广、体积较小的 AAC-LC `.m4a`，用于本地播放和系统分享。

iPhone 不再使用 S3，也不再读取旧版本备份到 S3 的录音。Recording API 暂不参与 App 链路，保留的服务端代码仅供后续 Agent/API 阶段重新接入。

## 当前实现

- iOS 18、SwiftUI、AVAudioEngine / AVAudioConverter；
- 连续 `24 kHz / mono / 16-bit PCM CAF` 本地源文件；
- 约 10 秒一个 `64 kbps AAC-LC .m4a` Chunk；
- `Recording / Chunk / UploadTask` 三表 SQLite（WAL + FULL synchronous）；
- Start / Pause / Resume / Finish 保持同一 `recording_id`；
- Live Activity、App Shortcuts、iOS 18 Control Center / Lock Screen Control、可选 Action Button；
- 本机合并并分享标准 AAC-LC M4A；
- 本地完成后即可开始下一场；录音中展示真实收音电平、输入设备和中断状态；
- Apple Watch：手表全程录音（60 秒分段同步到 iPhone 合成，再转给 Mac）；查看今日已录、待传分钟数和最近 7 天的录音记录；表盘复杂功能；
- 三个标签：「回顾」按天列出每段对话（标题、两行摘要、待办）和当天一句话回顾，「录音」一键开始，「搜索」同时搜原文和回答问题；设置在回顾页左上角；
- 完整录音库、持久化命名、本地字幕搜索、重点标记及 TXT/SRT 导出；
- 删除的录音先进入「最近删除」，保留 30 天后永久删除，期间可恢复；没有手动命名的录音，自动使用摘要标题，并在列表显示概述；
- iOS 26+ 设备端免费转写（SpeechAnalyzer）与摘要（Apple 智能），不需要任何服务；支持 AirPods 高质量录音和导入音频文件；
- 可选第三方服务：转写接入 OpenAI 兼容的 `/audio/transcriptions`，摘要和提问接入 OpenAI 兼容 API 或 Claude API，见[说明](docs/ai-providers.md)；
- 系统自适应浅深色、大字体布局；
- macOS 原生 App：全天麦克风录音、本机实时转录、每小时和每天总结、点句回放、搜索、导出，以及手表/iPhone 回传合并；不录线上会议的系统声音。
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
- [macOS App](macos/README.md)

连接 iPhone 后运行 `ios/install_device.sh <device-id-or-udid>` 完成构建和安装。首次使用只需在 Xcode 选择自己的 Development Team，并在 iPhone 上允许麦克风访问。

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
