# WakeOnCue iOS Recording MVP Goal

实现独立的 Native iOS 18 会议录音与云端同步 App：本地音频是 Source of Truth；录音持续产生约 10 秒 AAC Chunk，并通过持久化 Background URLSession 队列直接上传用户配置的 S3；断网或云端失败不得中断本地录音。

第一阶段只完成：

```text
iPhone → Reliable Recording → Chunk Upload → User S3
```

不依赖 Omi，不在 iPhone 内实现 ASR、Chat 或 Agent。Recording API 与 Agent 接入推迟到后续阶段。具体范围、架构与验收分别见：

- `docs/mvp.md`
- `docs/architecture.md`
- `docs/api-contract.md`
- `docs/development.md`
- `docs/verification.md`

唯一完成标准是代码、完整 Xcode build 和目标真机验收矩阵全部通过。fixture、Swift 语法解析或服务端合成音频测试不能替代真机证明。
