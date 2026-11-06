import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings sections: recording, devices, transcription, voices, AI, storage and permissions.
struct SettingsView: View {
  enum Section: String, CaseIterable, Identifiable {
    case recording = "录音"
    case devices = "设备与回传"
    case transcription = "转录模型"
    case voices = "声音"
    case ai = "AI 服务"
    case storage = "存储"
    case permissions = "权限"
    var id: String { rawValue }
  }

  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var ui = model.ui
    let section = ui.settingsSection
    NavigationSplitView {
      List(Section.allCases, selection: $ui.settingsSection) { Text($0.rawValue).tag($0) }
        .navigationSplitViewColumnWidth(170)
    } detail: {
      Group {
        switch section {
        case .recording: RecordingSettings()
        case .devices: DevicesSettings()
        case .transcription: TranscriptionSettings()
        case .voices: VoicesSettings()
        case .ai: AISettings()
        case .storage: StorageSettings()
        case .permissions: PermissionSettings()
        }
      }
      .formStyle(.grouped)
      .navigationTitle(section.rawValue)
    }
    .frame(width: 760, height: 560)
  }
}

private struct RecordingSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var preferences = model.preferences
    Form {
      Section {
        Toggle(isOn: $preferences.alwaysRecord) {
          Text("全天录音")
          Text("登录后自动开始。Mac 休眠或合盖时录不了，这段会显示为没录音。")
        }
        .onChange(of: preferences.alwaysRecord) {
          if preferences.alwaysRecord {
            CrashRecovery.registerIfNeeded()
            Task { await model.recorder.startIfAllowed() }
          } else {
            model.recorder.turnOff()
          }
        }
        Picker("麦克风", selection: $preferences.microphone) {
          ForEach(MicrophoneChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .onChange(of: preferences.microphone) {
          guard model.recorder.isRecording else { return }
          Task { await model.recorder.resume() }
        }
        Text("使用 AirPods 麦克风时，播放的音质会下降，所以默认用内建麦克风。").font(.caption).foregroundStyle(.secondary)
      }
      Section("暂停") {
        LabeledContent("暂停或继续", value: "⌃⌥P")
        LabeledContent("暂停 1 小时、删除刚才的录音", value: "在菜单栏中")
      }
    }
  }
}

private struct TranscriptionSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        LabeledContent("实时转录") { SpeechStatusText(status: model.transcription.status) }
        LabeledContent("说话语言", value: "中文")
      } footer: {
        Text("Apple 语音一直负责边录边转。启用下载的模型后，每句话会在几秒后用它重新转录，替换 Apple 语音的结果；时间和说话人不变。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("可用模型") {
        ModelList()
      }
      TranscriptionServiceSection()
      Section {
        LabeledContent("模型存放位置") {
          HStack {
            Text(TimeText.bytes(model.models.bytesOnDisk())).foregroundStyle(.secondary)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([ASRModels.directory]) }
          }
        }
      } footer: {
        Text("下载中断后会从断点继续，完成后按官方发布的 SHA-256 校验文件。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("说话人") {
        Text("麦克风里是你的声音算「我」，麦克风里的其他人算「他人」。录入你的声音、区分说话人和记住声音在设置 › 声音里。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct StorageSettings: View {
  @Environment(AppModel.self) private var model
  @State private var audioBytes: Int64 = 0
  @State private var freeBytes: Int64 = 0

  var body: some View {
    @Bindable var preferences = model.preferences
    Form {
      Section {
        let text = model.store.textBytes()
        let total = max(1, audioBytes + text)
        GeometryReader { geometry in
          HStack(spacing: 0) {
            Rectangle().fill(Color.sourceMac).frame(width: geometry.size.width * CGFloat(audioBytes) / CGFloat(total))
            Rectangle().fill(Color.sourceOther)
          }
          .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityLabel("音频 \(TimeText.bytes(audioBytes))，转录和总结 \(TimeText.bytes(text))")
        HStack(spacing: 16) {
          Label("音频 \(TimeText.bytes(audioBytes))", systemImage: "circle.fill").foregroundStyle(Color.sourceMac)
          Label("转录和总结 \(TimeText.bytes(text))", systemImage: "circle.fill").foregroundStyle(Color.sourceOther)
        }
        .font(.caption)
      } header: {
        Text("占用  共 \(TimeText.bytes(audioBytes + model.store.textBytes()))，磁盘剩余 \(TimeText.bytes(freeBytes))")
      }
      Section("保留多久") {
        Picker(selection: $preferences.audioRetentionDays) {
          Text("一直保留（推荐）").tag(0)
          Text("30 天").tag(30)
          Text("7 天").tag(7)
        } label: {
          Text("音频")
          Text("默认一直保留。选 7 天或 30 天后，过期只删音频，不能再回放，转录和总结还在。每天约 170 MB。")
        }
        Picker(selection: $preferences.textRetentionDays) {
          Text("一直保留").tag(0)
          Text("1 年").tag(365)
          Text("90 天").tag(90)
        } label: {
          Text("转录和总结")
          Text("文字很小，默认一直保留，方便以后搜索。")
        }
        LabeledContent {
          Button("立即清空…", action: confirmEmpty)
        } label: {
          Text("最近删除")
          Text("删除的内容 30 天后彻底删除")
        }
      }
      .onChange(of: preferences.audioRetentionDays) { model.cleanUp() }
      .onChange(of: preferences.textRetentionDays) { model.cleanUp() }
      Section("磁盘空间不足时") {
        Text("剩余不到 10 GB 时提醒；不到 2 GB 时暂停录音，并在菜单栏显示原因。不会自动删除录音。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("存放位置") {
          HStack {
            Text("~/Library/Application Support/WakeOnCue").foregroundStyle(.secondary)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Store.rootDirectory]) }
          }
        }
      }
      CommandLineSection()
    }
    .task { measure() }
  }

  private func measure() {
    var total: Int64 = 0
    if let files = FileManager.default.enumerator(at: Store.audioDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let url as URL in files {
        total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    }
    audioBytes = total
    let values = try? Store.rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  private func confirmEmpty() {
    let alert = NSAlert()
    alert.messageText = "彻底删除最近删除里的全部录音？"
    alert.informativeText = "删除后不能恢复。"
    alert.addButton(withTitle: "取消")
    let button = alert.addButton(withTitle: "彻底删除")
    button.hasDestructiveAction = true
    if alert.runModal() == .alertSecondButtonReturn {
      model.emptyRecentlyDeleted()
      measure()
    }
  }
}

private struct PermissionSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        row("麦克风", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, anchor: "Privacy_Microphone")
        LabeledContent("Apple 智能") {
          Text(AppleIntelligenceEngine.unavailableReason ?? "已打开")
            .foregroundStyle(AppleIntelligenceEngine.unavailableReason == nil ? .green : .secondary)
        }
        LabeledContent("总结") {
          Text(model.summaries.engineName.map { "使用\($0)" } ?? model.summaries.unavailableReason ?? "")
            .foregroundStyle(model.summaries.engineName == nil ? Color.recording : .green)
        }
        Toggle("登录时启动", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
      }
    }
  }

  private func row(_ title: String, ok: Bool, anchor: String, note: String? = nil) -> some View {
    LabeledContent {
      HStack {
        Text(ok ? "已打开" : "未打开").foregroundStyle(ok ? .green : Color.recording)
        Button("系统设置…") { AppModel.openPrivacySettings(anchor) }
      }
    } label: {
      Text(title)
      if let note { Text(note) }
    }
  }
}
