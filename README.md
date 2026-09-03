# WakeOnCue

WakeOnCue 是一个独立的 Native iOS 会议录音与云端同步 MVP。它不依赖 Omi，也不在 iPhone 内绑定任何 ASR、LLM 或 Agent。

```text
iPhone microphone
  → continuous local PCM source (Source of Truth)
  → 10-second AAC chunks
  → local completion (default)
  → optional persistent SQLite upload queue
  → user-configured S3 / S3-compatible storage
```

可靠性优先级是：本地录音 > 不丢数据 > 云端同步 > 交互 > 上传延迟 > 视觉效果。网络和服务端不参与麦克风到本地文件的写入路径。

现在也提供可选的实时分析旁路：iPhone 把 0.5 秒 PCM 帧发送到稳定 Realtime Gateway，由可替换 Processor 返回带说话人字段和 revision 的实时字幕。Gateway/Processor 故障不会影响本地录音；Mac 只是当前首个 Processor 运行环境，App 协议不依赖 Mac。

用户可在 iOS 设置中直接配置 AWS S3 或 S3 兼容存储；保存时由 iPhone 真实执行一次临时对象的写入、读取与删除验证，通过后才启用。凭据保存在 iOS Keychain。完成时 App 把 Chunk 合成为兼容性广、体积较小的 AAC-LC `.m4a`，用于 S3 最终文件、本地播放和系统分享。

未配置 S3 时，录音结束后由本机数据库直接完成；App 只展示“Saved locally”，不会显示 Uploading、Synced 或 Waiting。启用 S3 后才创建上传任务并展示按录音时长计算的云端同步进度。Recording API 暂不参与 App 链路，保留的服务端代码仅供后续 Agent/API 阶段重新接入。

## 当前实现

- iOS 18、SwiftUI、AVAudioEngine / AVAudioConverter；
- 连续 `24 kHz / mono / 16-bit PCM CAF` 本地源文件；
- 约 10 秒一个 `64 kbps AAC-LC .m4a` 上传 Chunk；
- `Recording / Chunk / UploadTask` 三表 SQLite（WAL + FULL synchronous）；
- `Background URLSession` 文件上传、断网等待、指数退避、进程恢复；
- AWS Signature Version 4 直连 S3，支持自定义 endpoint 与 path-style；
- Start / Pause / Resume / Finish 保持同一 `recording_id`；
- Live Activity、App Shortcuts、iOS 18 Control Center / Lock Screen Control、可选 Action Button；
- 本机合并并分享标准 AAC-LC M4A；
- 可选 Realtime Gateway、断线重连/事件补放和 App 内实时字幕；
- 可替换 Mac Processor：Qwen3-ASR-1.7B 实时初稿/原位修订（MLX Whisper 回退）+ sherpa-onnx 说话人分割与声纹聚类；
- Swift 核心单元测试、真实 S3 兼容端点 round-trip 和真实 AAC/M4A 验证。

详细说明：

- [系统架构](docs/architecture.md)
- [Recording API Contract](docs/api-contract.md)
- [本地开发与真机启动](docs/development.md)
- [MVP 范围与验收](docs/mvp.md)
- [验证结果](docs/verification.md)
- [实时处理协议与部署](docs/realtime-processing.md)

想在自己的 MacBook 上直接跑实时服务，可从仓库根目录执行
`server/scripts/setup_mac.sh` 后运行 `server/scripts/run_local_mac_stack.sh`；连接
iPhone 后运行 `ios/install_device.sh <device-id-or-udid>` 完成构建和安装。首次使用只需
在 Xcode 选择自己的 Development Team，并在 iPhone 上允许麦克风和本地网络访问。

## 配置存储

默认无需任何服务，录音保存在 iPhone。需要云端同步时，在 App 设置中启用 S3，填写 Bucket、Region、Access Key、Secret Key；非 AWS 的兼容服务再填写自定义 Endpoint，并按服务要求启用 path-style。Save 验证成功后，仅后续新录音会直接同步到该存储。

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
