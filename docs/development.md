# Local Development and Device Validation

## 1. Prerequisites

- macOS；
- 完整 Xcode（含 iOS 18 或更高 SDK）；
- iOS 18+ iPhone；
- ffprobe（仅用于音频验收）；
- XcodeGen 2.46+（仅修改 `ios/project.yml` 后需要）。

```bash
brew install ffmpeg xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 1.1 Open-source Mac quick start

从 GitHub clone 后，在仓库根目录执行：

```bash
server/scripts/setup_mac.sh
server/scripts/run_local_mac_stack.sh
```

这会创建服务端虚拟环境、安装 Gateway/Processor 依赖，并在 macOS Keychain
生成随机的实时 Gateway token。默认使用 MLX Whisper 回退处理器，适合先验证流程；
如果已经准备好 Qwen3-ASR-1.7B 模型，可执行：

```bash
WAKEONCUE_ASR_BACKEND=qwen server/scripts/setup_mac.sh
WAKEONCUE_ASR_BACKEND=qwen WAKEONCUE_QWEN_MODEL=/absolute/path/to/Qwen3-ASR-1.7B \
  server/scripts/run_local_mac_stack.sh
```

`run_local_mac_stack.sh` 只启动局域网 Gateway，不需要 Cloudflare、固定公网域名或
同一台机器上的额外服务。保持终端运行，iPhone 与 Mac 连接同一 Wi-Fi 后，App 会通过
Bonjour 自动发现 Mac；若局域网不可用，才使用 App 设置中配置的公网 Gateway。第一次
运行 macOS 防火墙或 iOS “本地网络”权限提示时请选择允许。

当前 Mac 的系统级 `xcode-select` 仍可能指向 Command Line Tools；上面的 `DEVELOPER_DIR` 可直接使用完整 Xcode，无需管理员权限。若要全局切换，可手动运行 `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`。

## 2. Storage

本地模式不需要启动任何服务。直连 S3 测试需要一个测试 Bucket 和权限受限的测试凭据；也可使用 MinIO 等 S3-compatible 服务。App 保存配置时会执行临时对象 PUT、HEAD、DELETE，失败不会替换当前生效配置。

实时文字是独立可选能力。Gateway 和 Mac Processor 的启动、真机地址及迁移边界见 [Realtime Processing](realtime-processing.md)。设置页保存实时处理配置时会调用受 token 保护的 `/v1/realtime/validate`；验证失败不会启用配置。

## 3. Configure Signing

1. 打开 `ios/WakeOnCue.xcodeproj`；
2. 为 `WakeOnCue` 和 `WakeOnCueWidgets` 选择 Development Team；
3. 在 Developer Portal / Signing & Capabilities 创建同一 App Group；
4. 若不用默认 `group.com.deoooo.WakeOnCue`，同步修改：
   - `ios/project.yml`
   - `ios/WakeOnCue/WakeOnCue.entitlements`
   - `ios/WakeOnCueWidgets/WakeOnCueWidgets.entitlements`
   - `ios/Shared/SharedRecordingState.swift`
5. 修改 project.yml 后运行 `cd ios && xcodegen generate`。

App target 需要 Background Modes / Audio。Widget Extension 承载 Live Activity 与 iOS 18 Control。

项目不再写死任何开发者 Team ID。连接已解锁并信任的 iPhone 后，也可以直接运行：

```bash
ios/install_device.sh <device-id-or-udid>
```

脚本会重新生成 Xcode 工程、执行签名构建并安装 App；如自动签名无法选择 Team，先在
Xcode 的 Signing & Capabilities 选择自己的 Team，或设置 `DEVELOPMENT_TEAM` 环境变量。
App Group 和 Bundle ID 必须在自己的 Apple Developer 账号下唯一，开源使用者应按账号
需要修改 `ios/project.yml` 与两个 entitlements。

## 4. Run on iPhone

1. 默认保持 Local only；需要 S3 时在 App 设置填写 Bucket、Region、凭据和可选 Endpoint，Save 验证成功；
2. 首次从 App 内点 Allow Microphone；
3. 点大号录音按钮，观察本地计时和每约 10 秒增加 Chunk；
4. 在 Control Center 编辑界面添加 WakeOnCue Meeting Recording Control；
5. 可把同一 Control 添加到锁屏或支持的 Action Button；
6. 打开 Live Activity，检查 Pause / Resume / Finish。

首次权限未授予时，锁屏或 Control 不能绕过系统权限提示。必须先在 App 内完成授权。

## 5. Build and Tests

```bash
cd ios
xcodebuild \
  -project WakeOnCue.xcodeproj \
  -scheme WakeOnCue \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build test
```

纯 Swift 核心：

```bash
cd ios/Packages/WakeOnCueCore
swift test
```

保留的未来 Recording API 测试（当前 App 不调用）：

```bash
cd /path/to/WakeOnCue
PYTHONPATH=server python3 -m unittest discover -s server/tests -v
```

## 6. Reliability Runs

每个 Case 保存：设备型号、iOS 版本、App commit、开始/结束时间、录音 ID、Chunk 数、S3 object 列表、最终 M4A 时长、主观缺口检查和结果。

### 60-minute recording

录音 60 分钟，完成后下载 S3 `source.m4a`；用 ffprobe 比较 S3 文件时长和本地记录时长，并试听开始、中间、结束位置。

### Offline 10 minutes

录音开始并看到至少 2 个 Chunk 已同步；关闭 Wi-Fi 和 Cellular 10 分钟；确认计时继续且 Waiting 时长增长；恢复网络；等待 Waiting=0；确认 S3 Chunk key 连续且无重复。

### Lock screen 30 minutes

开始后锁屏 30 分钟；Live Activity 持续显示；解锁后确认本地时长、Chunk 和最终音频。

### Background apps

开始后使用 Safari、微信等；回到 WakeOnCue 确认录音未停止。

### Pending queue relaunch

断网产生 pending；终止 App 并重新打开；确认上传任务恢复。注意：用户 Force Quit 会停止正在运行的麦克风，测试重点是已经封口的 Chunk 和队列恢复，不能把 Force Quit 后继续录音设为普通 iOS App 的预期。
