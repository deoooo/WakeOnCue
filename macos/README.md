# WakeOnCue for Mac（第一期）

全天录音、实时转录、每小时和每天总结的 Mac App。需要 macOS 26 和 Apple 芯片，不依赖 Python，转录和总结都在本机完成。

## 构建

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成：

```bash
cd macos
xcodegen generate
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCue -configuration Debug -derivedDataPath build/DerivedData build
```

### 测试

`WakeOnCueTests` 只编译纯逻辑的源文件（转录过滤、总结素材和提示词），不启动 App，所以不会开始录音：

```bash
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCue -configuration Debug -derivedDataPath build/DerivedData test
```

### 签名和权限

macOS 按 App 的代码签名记住麦克风权限。ad-hoc 签名每次编译都会变，系统就会每次重新询问。首次构建前运行一次：

```bash
scripts/setup-signing.sh
```

它会从钥匙串里找到 Apple Development 证书（免费 Apple ID 在 Xcode › 设置 › 账户 里就能创建），把团队写进不提交的 `Local.xcconfig`。之后无论用命令行还是 Xcode 构建，签名都保持不变，权限只需授权一次。也可以手动指定团队：`scripts/setup-signing.sh TEAMID`。

没有 `Local.xcconfig` 时仍能构建，只是用 ad-hoc 签名，构建时会给出警告。正式分发的版本用 Developer ID 签名，用户那边不会遇到反复授权。

## 结构

| 目录 | 内容 |
| --- | --- |
| `Capture` | 麦克风（AVCaptureSession，固定用内建麦克风）、分段写入（16 kHz、32 kbps AAC，ADTS 格式，崩溃后仍可读）、暂停、休眠恢复、磁盘空间检查 |
| `Transcription` | `SpeechAnalyzer` 实时中文转录，按标点切句，丢掉噪声里听出的单个字母和「Thank you」（`TranscriptFilter`）；说话人分「我」「他人」。可下载的模型（`ASRModels.swift` 里的清单：Qwen3-ASR 0.6B 走 sherpa-onnx、在 CPU 上跑；Qwen3-ASR 1.7B 走 MLX、在 GPU 上跑）重新转录：间隔不到 1 秒的相邻句子拼成最长 20 秒一起识别，句尾多取 1 秒（Apple 语音的句子结束得偏早，但不越过下一句），再按和实时文字的逐字对齐、在标点处拆回各句，时间、说话人和句子编号不变（`SentenceGroups.swift`）。小时和当天都能手动「重新转录」，用当前选的模型（没选时用 Apple 语音整句重转），文字变了的小时会自动重新总结。模型回复里的特殊符号和其后编出来的文字会被截掉，没有中文或没听出内容的回复不会覆盖实时转录。重转前把偏小的音量拉高（最多 +24 dB）；设置 › 转录里的「常用词」作为 Qwen3-ASR 的热词（转录服务则作为 prompt），模型只念出热词的回复会被丢弃（`Vocabulary.swift`） |
| `Storage` | SQLite（句子、分段、私人和删除时段、录不了的原因、总结） |
| `Intelligence` | 每小时总结和要点句、当天总结，都带引用。送去总结前去掉「嗯」「对」这类应答；只有零星几句的小时不生成总结；当天总结给每个小时同样的篇幅，要点覆盖全天；模型说上下文放不下时把这一段对半再试（`SummaryMaterial`）。提示词会说明远处的人声音小、周围不相干的谈话不写，并附上「常用词」；设置 › AI 服务里的「每日例会」所在小时写成例会纪要（进展、计划、问题、待办）。引擎是本机 Apple 智能（Foundation Models），或用户配置的 OpenAI 兼容网关（API Key 存钥匙串）。换了引擎后，旧总结旁会注明由哪个引擎生成，可以按小时或当天重新生成 |
| `Sync` | 接收已配对 iPhone 转来的手表和 iPhone 录音：扫码配对、TLS-PSK 加密、断点续传、SHA-256 校验后入库，协议见 [docs/sync-protocol.md](../docs/sync-protocol.md) |
| `Playback` | 跨分段连续播放，麦克风和手表/iPhone 回传音频同时播放，跳过私人和已删除的时段 |
| `UI` | 主窗口、搜索、最近删除、菜单栏、首次使用、设置 |

数据存放在 `~/Library/Application Support/WakeOnCue`，下载的模型在其中的 `Models/`。

### 可下载的转录模型

模型都在用户点「下载」时才下载，默认仍用 Apple 语音，不会自动下载。设置里给适合这台 Mac 的模型标「推荐」：内存 16 GB 及以上推荐 1.7B，否则推荐 0.6B（`ASRModel.recommended`），首次设置时也展示这一个。

- **Qwen3-ASR 0.6B**：模型和 sherpa-onnx 运行库从 k2-fsa/sherpa-onnx 的官方 GitHub Releases 下载，按发布页的 SHA-256 校验后解压，运行时用 `dlopen` 载入（因此开启了 `com.apple.security.cs.disable-library-validation`）。仓库里只有 C 头文件，见 `Vendor/sherpa-onnx`。
- **Qwen3-ASR 1.7B**：sherpa-onnx 还没有官方 1.7B 包，改用 Hugging Face 上 mlx-community 的 8-bit MLX 版，固定到一个提交，逐个文件下载并按 SHA-256 校验（`HubSnapshot`），用 mlx-audio-swift 在 GPU 上识别（`MLXRecognizer`）。运行时约占 3–4 GB 内存。编译需要 Xcode 的 Metal 工具链：`xcodebuild -downloadComponent MetalToolchain`。

加一个新模型只需在 `ASRModel.catalog` 里加一条。

## 命令行工具

App 里带了一个只读的命令行工具 `WakeOnCue.app/Contents/Helpers/wakeoncue`（源码在 `WakeOnCueCLI/`，和 App 共用 `Storage` 的代码）。在设置 › 存储 › 命令行里点「安装」，就会在 `~/.local/bin` 下建一个链接。

```bash
wakeoncue day                      # 今天的总结和每小时总结
wakeoncue day 昨天 --json
wakeoncue transcript --hour 10     # 今天 10 点这一小时的原文
wakeoncue transcript 11-03 --from 14:30 --to 15:00
wakeoncue search 告警 灰度 --days 7 --speaker 他人
wakeoncue export 昨天 > 昨天.md     # 整天：当天总结、每小时总结和全部转录
wakeoncue export --hour 10 --format srt > 10点.srt   # 字幕时间从 10:00 算起
wakeoncue health --days 3          # 全天录音体检：没有原因的空档、有转录没总结、回传进度
wakeoncue conversations 昨天        # 这一天切成的对话（同步给 iPhone 的单位）
```

`export` 输出的内容和 App 里「导出…」（工具栏、文件 › 导出这一天… ⌘E、小时的「…」菜单）保存的文件完全一样，格式化代码在 `Export/Export.swift`，单元测试在 `WakeOnCueTests/`（`xcodebuild … test`，不启动 App）。格式：`md`（默认，带总结、时间和说话人）、`txt`（纯转录）、`srt`（时间相对所选范围的起点）。

所有命令都可以加 `--json`，方便脚本和 Claude 等 AI 工具使用。标为私人或已删除的时段不会出现在任何结果里。它只读打开数据库，App 运行时也可以用。

## 调试

Debug 构建可以让 App 每隔几秒把自己的窗口截成 PNG，并执行 `<路径>.cmd` 里的命令（见 `App/DebugSnapshot.swift`），用于在没有鼠标的情况下检查界面：

```bash
defaults write com.deoooo.WakeOnCue.macos debugSnapshot /tmp/wakeoncue.png
```
