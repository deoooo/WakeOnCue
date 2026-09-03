# WakeOnCue iOS Recording MVP

## Milestone 1

```text
iPhone → Reliable local recording → Chunk upload → User S3
```

## 必做

- iOS 18 Native Swift / SwiftUI；
- App 首页、Control Center、锁屏 Control、App Shortcuts 和可选 Action Button；
- Start / Pause / Resume / Finish，同一会议保持同一 `recording_id`；
- 连续本地源文件和约 10 秒 AAC Chunk；
- Recording / Chunk / UploadTask 本地数据库；
- Background URLSession、断网等待、重试、重启恢复；
- Live Activity 明确显示录音、时长、上传量和 pending；
- 用户自定义 S3/S3-compatible 配置、直连验证和 SigV4 上传；
- S3 保存 metadata、原始 Chunk 和本机合并后的完整 M4A；
- 文档、测试和已验证/未验证边界。

## 不做

Recording API、Agent/Webhook、macOS、Android、BLE、Omi、实时字幕、ASR、内置 Chat、AI Summary UI、Calendar、Contact、复杂账户、多用户协作和社交功能。

## 真机验收矩阵

| Case | 操作 | 通过标准 |
|---|---|---|
| 1 正常会议 | 连续录音 60 分钟 | 无中断、无明显缺口、Chunk 数正确、云端完整音频 |
| 2 断网 | 中途关闭 Wi-Fi + Cellular 10 分钟 | 本地继续；恢复后自动补传；无丢失、无重复 |
| 3 锁屏 | 锁屏录音 30 分钟 | 持续录音；上传尽力继续；最终完整 |
| 4 切后台 | 使用微信、Safari 等 | 后台持续录音 |
| 5 重启 | 存在 pending Chunk 时终止并重开 | 队列恢复；已完成 Chunk 不丢失 |
| 6 非 Action Button | 仅 App / 锁屏 / Control Center | 可以开始与结束会议 |
| 7 分享 | 从历史录音分享 | 分享真实 `.m4a` 文件，接收方可直接播放 |

执行结果记录在 [verification.md](verification.md)。没有真机证据的 Case 不能标记 PASS。
