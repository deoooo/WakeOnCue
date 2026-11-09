# Apple Watch 接入

Watch 负责**离开电脑时的全天录音**：手表自己录，每分钟一段经 iPhone 回传到 Mac（见 [macos-app.md](macos-app.md)）。手表界面只做两件事：开始/结束录音，看录了多少、传到 iPhone 多少。

> 2026-11-09 起手表界面重做：去掉「记下刚才」（标记最近 2 分钟与待办/重要/想法标签）、点标记、遥控 iPhone 录音和对应的表盘快捷入口，新增录音记录页。iPhone 和 Mac 仍能读取旧版本留下的标记（协议见 [sync-protocol.md](sync-protocol.md) 的 `marks`），手表不再产生新标记。iPhone 端的遥控处理代码暂时保留，手表不再调用。

## 界面

| 页面 | 内容 |
| --- | --- |
| 主页 | 一屏不滚动。左上角空闲显示 WakeOnCue、录音中显示「● 录音中」；大数字空闲时是「今天已录」（时:分），录音中是本次计时，下面一条音量条；再下一行是送达状态：全部已传到 iPhone / N 分钟待传 iPhone / N 分钟待传 · iPhone 不在身边 / 正在和 iPhone 收尾。底部工具栏：左边「录音记录」，中间圆形录音键（空闲橙色麦克风，录音中白底红色停止）。录音中整屏红色背景。出错提示临时替代送达状态那一行 |
| 录音记录 | 最近 7 天的手表录音按天分组，每条一行：起止时间、时长（异常结束时追加「来电打断 / 存储失败 / 意外退出」），右侧是已传到 iPhone 的勾、待传进度「267/270」或录音中的红点 |
| 表盘复杂功能 | 只显示手表录音状态（圆形/矩形/角落/行内，录音中带实时计时） |

送达状态只到 iPhone 为止：分段按 60 秒切，「分钟」就是分段数；iPhone 确认收到某段后手表删除该段文件，所以「待传」就是手表上还留着的已完成分段。是否已从 iPhone 转到 Mac 手表不知道，要显示需要 iPhone 在下发状态里补字段。

录音全部送达后，手表只保留 `state.json`（几百字节）用于录音记录页，7 天后删除。

## 手表录音

```text
Watch 点「开始录音」→ 手表录音（不再先尝试让 iPhone 录）
  → 16 kHz 单声道 32 kbps AAC，每 60 秒一个 segment-NNNN.m4a（Documents/Recordings/<session>/）
  → 每段写完即 transferFile 给 iPhone；送达确认后删除手表上的音频文件
  → 「结束」后 transferUserInfo 发送会话摘要（起止时间、段数、结束原因）
  → iPhone 暂存于 Application Support/WatchInbox/sessions/<session>/，段齐后合成一条本地录音，并转发给 Mac
```

- iPhone 端录音 ID 为 `rec_watchrec_<session>`，`metadata.source = apple_watch`，每段是一个 chunk。
- 摘要到达 24 小时后仍缺段时，用已到的段合成，避免永远挂起。
- 手表 App 意外退出（没电、被系统回收）：下次启动时把已写完的段结束成一条录音（`endReason=recovered`），最多丢失最后一段（≤60 秒）。
- 来电、Siri 打断：结束这条录音（`endReason=interruption`），watchOS 不允许后台恢复录音，主页提示回到 App 重新开始。
- 分段打开或写入持续失败（例如存储已满）：结束这条录音（`endReason=write_failure`），保存已完成的分段，手表震动并显示提示。详见下文「写入失败」。

## 代码位置

- `ios/WatchShared/`：iPhone 与 Watch 共用的协议（`WatchBridgeProtocol.swift`）与复杂功能读取的录音开始时间（`WatchSnapshotStore.swift`）。
- `ios/WakeOnCue/Watch/`：`PhoneWatchBridge`（WCSession）与 `WatchRecordingImporter`（分段合成）。
- `ios/WakeOnCueWatch/`：独立 watchOS App（SwiftUI）。`WatchAudioRecorder` 分段录音，`WatchRecordingStore` 负责持久化、补发与崩溃恢复，`WatchDiagnostics` 是 Debug 诊断日志。
- `ios/WakeOnCueWatchWidgets/`：WidgetKit 复杂功能 / Smart Stack。
- `ios/WatchResources/`：Watch 端中英文文案。
- `ios/WatchShared/SegmentWriter.swift`：分段写入与失败判定。只有手表录音用到，放在共用目录是为了能被 `WakeOnCueTests` 测试。

## 写入失败

以前下一段打开失败后，音频会被静默丢弃，界面仍显示在录音；单次写入失败也只记日志。现在 `SegmentWriter` 的规则是：

- **先开下一段，再关当前段。** 下一段打不开时，音频继续写进当前段（这一段会超过 60 秒），不丢音频，并在之后每批音频到达时重试。序号只在打开成功后才增加，段号不会出现空缺。
- **写入失败：** 这批音频无法保留，时间线相应变短。短暂失败不结束录音，因为手表无法在后台重新开始录音。
- **失败额度（`SegmentFailureBudget`）：** 按音频时长计算，失败累计到 5 秒就结束录音。成功写入只按 0.1 倍抵扣，所以失败和成功交替时也会结束。5 秒和 0.1 是估计值，没有真机数据支持。
- **合上后读回校验：** 打不开或长度为 0 的段会被删除且不计入段数，因为 iPhone 读不了时长就会导致整条录音一直导入失败。整段写满时校验失败会立即结束录音；用户手动结束时只丢这一段，Debug 日志有记录，但提示仍是「已保存」。

结束时走与中断相同的路径：`WatchAudioRecorder` 先调用 `onStopped`，由 `WatchModel` 结束录音并发送摘要。此时录音尚未关闭，所以摘要的段数包含最后一段。修改前的中断路径先关闭录音，摘要发出时最后一段还没计入，iPhone 合成时会漏掉这一段（≤60 秒）；这次一并修复。

用户看到的提示：手表震动（`.failure`），主界面从录音状态退出并显示说明文字；一段也没保存下来时会明确说明没有保存。文字会保留到被下一条提示替换。

已知局限：

- 总失败比例低于约 9% 时不会结束录音，这些丢失不提示用户，只在 Debug 日志记录每轮失败的第一条（额度归零后再次失败才会再记）。
- 存储全满时 `state.json` 也可能写不进去。摘要会用内存中的正确状态发送，但如果 App 随后被杀，下次启动的恢复流程读到的仍是旧状态，可能删除实际已完成的最后几段。
- 没有使用本地通知（需要新增权限申请），抬腕前只有一次震动。

**验证情况：** `SegmentWriterTests` 在 iOS Simulator 上用真实 AAC 文件加注入的故障，覆盖了判定和分段逻辑。`WatchAudioRecorder` 和 `WatchModel` 的接入部分只做过 watchOS Simulator 构建，没有运行。**以下只有真机才能验证（均未进行）：** 真实存储已满时 `AVAudioFile` 的报错方式与合上后的文件状态；App 在后台时 `.failure` 震动能否送达；提示文字的实际显示效果。

## 构建与验证

需要在 Xcode › Settings › Components 中安装 watchOS 平台（或 `xcodebuild -downloadPlatform watchOS`），否则内嵌 Watch App 的 `WakeOnCue` scheme 无法构建。安装到 iPhone 后，Watch App 会通过 iPhone 上的 Watch App 安装；免费账号同样需要每 7 天重签。

免费个人团队签名：App Group 只能由 Xcode 图形界面注册。首次真机安装前，在 Xcode 的 Signing & Capabilities 里给 `WakeOnCue`、`WakeOnCueWidgets`、`WakeOnCueWatch`、`WakeOnCueWatchWidgets` 选 Team 并确认 `group.com.deoooo.WakeOnCue`；之后可用 `DEVELOPMENT_TEAM=<team> ios/install_device.sh <iPhone>` 构建。手表需开启开发者模式，并用手表为目标构建一次（`-allowProvisioningDeviceRegistration`），让手表 UDID 进入描述文件。

### 真机验证（2026-10-25，iPhone Air + Apple Watch Series 9，旧版遥控与「记下刚才」，均已移除）

| 场景 | 结果 |
| --- | --- |
| 手表「开始记录」远程开始 iPhone 录音 | ✅ 约 1.5 秒生效 |
| iPhone 录音中「记下刚才」→「待办」 | ✅ 约 1 秒出现确认；书签 `position 62.7s, duration 120s, tag todo` |
| 手表「结束录音」 | ✅ 约 2 秒后 iPhone `COMPLETED` |
| iPhone 空闲，手表缓冲「记下刚才」→「想法」（已移除的旧功能） | ✅ 验证了 `transferFile` 真机可用：片段送达并导入，两端队列清空 |
| 手表独立录音（iPhone 锁屏时兜底） | ✅ 见下方日常使用结果（2026-10-27/28） |

已知现象：从手表远程开始录音后，iPhone 的实时活动会同步到手表并弹出提醒，短暂盖住 App，期间的点按会落在提醒上。

端到端 UI 测试（默认跳过，需要麦克风权限）：`TEST_RUNNER_WAKEONCUE_WATCH_E2E=1 xcodebuild test -scheme WakeOnCueWatch -only-testing:WakeOnCueWatchUITests/WatchCaptureUITests`，录 65 秒后结束并打开录音记录页。

仍待真机验证的问题（与方案文档的风险清单一致）：

- iPhone App 被系统挂起或锁屏时，Watch 发起「开始记录」可能被 iOS 后台录音限制拒绝，Watch 会提示到 iPhone 上开始（真机测试时 iPhone App 在前台）。

### 日常使用结果：手表全程录音（2026-10-27/28，Apple Watch Series 9）

两次都是 iPhone 无法开始录音（锁屏/后台，`iPhone start failed`）后自动改由手表录音，用户手动结束。

| 录音 | 时长 | 分段 | 心跳间隔 >20 秒 | 中断 | 送达 |
| --- | --- | --- | --- | --- | --- |
| 10-27 20:25–23:07 | 2.7 小时 | 163 | 0 | 0 | 163/163（最后 23 段在次日打开 App 时补发） |
| 10-28 08:57–22:51 | **13.9 小时** | 834 | 0 | 0 | 834/834；段写完到送达中位数 27 秒、P90 45 秒，最长约 46 分钟（推测 iPhone 不在身边） |

iPhone 端两条都合成为 `COMPLETED`，分段连续（1–163、1–834），时长与手表一致。发现并修复两个问题：

- 10-27 那条的合成 M4A 为 0 KB：iPhone App 被后台唤起接收分段时开始导出 2.7 小时音频，导出中途被挂起留下空文件，下次合成看到"文件已存在"就跳过了。现在先导出到 `.partial.m4a` 再原子改名，已有文件需非空且能读出时长才算有效，并在导出期间申请后台执行时间；空文件在下次播放时自动重新合成。
- `ended_at` 记成了 iPhone 合成的时间（可能晚很多），现在使用手表摘要里的实际结束时间。
- 合成只在 iPhone App 运行时发生：10-27 的录音次日 13:01 才合成，10-28 的录音 10-29 15:57 才合成。
- 存储：每小时约 15 MB 分段 + 约 10.6 MB 合成 M4A，13.9 小时共约 360 MB。

整机掉电（含日常使用，电量按 5% 取整）：

- 10-27：40% → 25% 用 2.7 小时，约 **5.5%/小时**。
- 10-28 上午：50% → 25% 用 4.3 小时，约 **5.8%/小时**；13:17–14:12 充电到 90%，**录音在充电期间没有中断**。
- 10-28 下午到晚上：90% → 60% 用 7.5 小时，约 **4%/小时**。
- 按 4–6%/小时，满电可支撑约 17–25 小时「全程录音 + 日常使用」；Series 9 标称典型续航 18 小时（约 5.5%/小时），录音带来的额外耗电不明显，但需同强度不录音的对照才能精确区分。

### 日常使用结果（2026-10-25，Apple Watch Series 9，旧版回溯缓冲）

麦克风与采样转换一直在跑，和全程录音只差 AAC 编码与写文件，可作为手表录音耗电的下限参考。

- 缓冲 17:19:54 开启，17:21:54 转入后台，此后**连续 170.8 分钟**、680 次心跳无一次超过 15 秒的间隔，没有音频中断。
- 20:10 后心跳停止且没有停止日志，此时电量 1%，下一条是次日 00:08 的 `process launched`：手表电量耗尽关机，不是系统回收。
- 电量 15% → 1% 用了约 170 分钟。整机平均掉电约 **5%/小时**（10%→5% 用 55 分钟，5%→1% 用 50 分钟），包含日常使用和 10% 以下的低电量状态；作为参照，Series 9 标称续航 18 小时，约合 5.5%/小时。
- watchOS 报告的电量按 5% 取整，且开启监测后的首次读数可能是旧值；已改为进程启动即开启监测。

### 后台录音的系统限制

- 真机实测（2026-10-25，旧版缓冲，同一采集管线）：前台开启后转入后台，心跳每 15 秒不间断，后台录到的音频全程有真实环境声；日常使用中连续运行 170.8 分钟直到手表没电。
- Apple 文档没有给出时长上限：音频等后台会话「until the current session ends」，且须在前台启动（[Background execution](https://developer.apple.com/documentation/watchkit/background-execution)）。
- Apple 工程师在论坛确认：录音可在前台开始后继续到后台，但被来电、Siri 打断后无法在后台恢复，必须由用户回到前台重新开启（[forums/750432](https://developer.apple.com/forums/thread/750432)）。当前实现在中断时结束这条录音并保存已录部分。
- 因此系统侧的停止只来自两类：音频中断（日志有 `audio interruption` / `recording stopped reason=interruption`），或进程被回收（心跳中断后出现 `process launched` 与 `recovered session`）。App 自身还会因写入失败而结束录音（`recording stopped reason=write_failure`）。

### 诊断日志（仅 Debug 构建）

手表 App 写入 `Documents/diagnostics.log`：进程启动、前后台切换、录音开始/结束及原因、iPhone 开始失败原因、音频中断、每 15 秒音频心跳、分段/摘要送达、录音中每 5 分钟电量；超过 2 MB 自动重来。读取：

```bash
xcrun devicectl device copy from --device <watch-udid> --domain-type appDataContainer --domain-identifier com.deoooo.WakeOnCue.watchkitapp --source Documents/diagnostics.log --destination diagnostics.log
```
