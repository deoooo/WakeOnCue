# WakeOnCue for Mac（第一期）

全天录音、实时转录、每小时和每天总结的 Mac App。需要 macOS 26 和 Apple 芯片，不依赖 Python，转录和总结都在本机完成。

## 构建

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成：

```bash
cd macos
xcodegen generate
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCue -configuration Debug -derivedDataPath build/DerivedData build
```

### 签名和权限

macOS 按 App 的代码签名记住麦克风、系统声音和日历权限。ad-hoc 签名每次编译都会变，系统就会每次重新询问。首次构建前运行一次：

```bash
scripts/setup-signing.sh
```

它会从钥匙串里找到 Apple Development 证书（免费 Apple ID 在 Xcode › 设置 › 账户 里就能创建），把团队写进不提交的 `Local.xcconfig`。之后无论用命令行还是 Xcode 构建，签名都保持不变，权限只需授权一次。也可以手动指定团队：`scripts/setup-signing.sh TEAMID`。

没有 `Local.xcconfig` 时仍能构建，只是用 ad-hoc 签名，构建时会给出警告。正式分发的版本用 Developer ID 签名，用户那边不会遇到反复授权。

## 结构

| 目录 | 内容 |
| --- | --- |
| `Capture` | 麦克风（AVCaptureSession，固定用内建麦克风）、按 App 录声音（Core Audio process tap）、分段写入（16 kHz、32 kbps AAC，ADTS 格式，崩溃后仍可读）、暂停、休眠恢复、磁盘空间检查 |
| `Transcription` | `SpeechAnalyzer` 实时中文转录，按标点切句；说话人分「我」「会议对方」「他人」；外放时去掉麦克风录到的会议声音 |
| `Storage` | SQLite（句子、分段、私人和删除时段、录不了的原因、总结、会议） |
| `Intelligence` | Apple 智能（Foundation Models）生成每小时总结和要点句、当天总结、会议要点，都带引用 |
| `Meetings` | 日历关联，按实际说话调整起止；没有日历的会议 App 通话；手动标成会议 |
| `Playback` | 跨分段连续播放，麦克风和会议声音同时播放，跳过私人和已删除的时段 |
| `UI` | 主窗口、会议面板和纪要、搜索、最近删除、菜单栏、首次使用、设置 |

数据存放在 `~/Library/Application Support/WakeOnCue`。

## 调试

Debug 构建可以让 App 每隔几秒把自己的窗口截成 PNG，并执行 `<路径>.cmd` 里的命令（见 `App/DebugSnapshot.swift`），用于在没有鼠标的情况下检查界面：

```bash
defaults write com.deoooo.WakeOnCue.macos debugSnapshot /tmp/wakeoncue.png
```
