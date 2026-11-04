import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings with the phase 1 sections: recording, transcription, calendar, storage, permissions.
struct SettingsView: View {
  enum Section: String, CaseIterable, Identifiable {
    case recording = "录音"
    case transcription = "转录模型"
    case ai = "AI 服务"
    case calendar = "日历"
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
        case .transcription: TranscriptionSettings()
        case .ai: AISettings()
        case .calendar: CalendarSettings()
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
      Section {
        ForEach($preferences.meetingApps) { $app in
          Toggle(isOn: $app.enabled) {
            HStack(spacing: 6) {
              Text(app.name)
              if model.recorder.activeMeetingApps.contains(app.name) {
                Text("正在录").foregroundStyle(.secondary)
              } else if !app.note.isEmpty {
                Text(app.note).foregroundStyle(.secondary)
              }
            }
          }
          .contextMenu {
            if !MeetingApp.defaults.contains(where: { $0.id == app.id }) {
              Button("从清单移除") { preferences.meetingApps.removeAll { $0.id == app.id } }
            }
          }
        }
      } header: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("录制这些 App 的声音")
            Text("只录 App 播放的声音，你说的话由麦克风录下。").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("添加 App…", action: addApp)
        }
      }
      Section("暂停") {
        LabeledContent("暂停或继续", value: "⌃⌥P")
        LabeledContent("暂停 1 小时、删除刚才的录音", value: "在菜单栏中")
      }
    }
    .onChange(of: preferences.meetingApps) { model.recorder.refreshMeetingAudio() }
  }

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
    let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    guard !model.preferences.meetingApps.contains(where: { $0.matches(id) }) else { return }
    model.preferences.meetingApps.append(MeetingApp(name: name, bundlePrefixes: [id], enabled: true))
  }
}

private struct TranscriptionSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        LabeledContent("实时转录用", value: "Apple 语音")
        LabeledContent("说话语言", value: "中文")
      }
      Section("可用模型") {
        LabeledContent {
          SpeechStatusText(status: model.transcription.status)
        } label: {
          Text("Apple 语音")
          Text("系统提供，支持实时。第一期的默认选择")
        }
        LabeledContent {
          Text("第二期").foregroundStyle(.secondary)
        } label: {
          Text("下载第三方模型")
          Text("SenseVoice、Whisper 等，中文和中英混说更准")
        }
      }
      Section("说话人") {
        Text("麦克风里是你的声音算「我」，会议 App 那一路算「会议对方」，麦克风里明显更远、更轻的声音算「他人」。具体人名和记住声音在第二期。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct CalendarSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        LabeledContent("日历权限") {
          if model.meetings.calendarAccess == .fullAccess {
            Text("已打开").foregroundStyle(.green)
          } else {
            Button("打开…") { Task { await model.meetings.requestCalendarAccess() } }
          }
        }
        Text("用会议名命名这段录音，并把参会人作为纪要的收件人。会议的起止时间按实际说话从日历时间延长或缩短，可在会议面板里手动调整。")
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
            Rectangle().fill(Color.sourceMeeting)
          }
          .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityLabel("音频 \(TimeText.bytes(audioBytes))，转录和总结 \(TimeText.bytes(text))")
        HStack(spacing: 16) {
          Label("音频 \(TimeText.bytes(audioBytes))", systemImage: "circle.fill").foregroundStyle(Color.sourceMac)
          Label("转录和总结 \(TimeText.bytes(text))", systemImage: "circle.fill").foregroundStyle(Color.sourceMeeting)
        }
        .font(.caption)
      } header: {
        Text("占用  共 \(TimeText.bytes(audioBytes + model.store.textBytes()))，磁盘剩余 \(TimeText.bytes(freeBytes))")
      }
      Section("保留多久") {
        Picker(selection: $preferences.audioRetentionDays) {
          Text("30 天（推荐）").tag(30)
          Text("7 天").tag(7)
          Text("90 天").tag(90)
          Text("一直保留").tag(0)
        } label: {
          Text("音频")
          Text("每天约 170 MB。过期后只删音频，不能再回放，转录和总结还在。")
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
        row(
          "会议 App 的声音", ok: model.recorder.meetingAudioIssue == nil, anchor: "Privacy_AudioCapture",
          note: model.recorder.meetingAudioIssue ?? "开会时自动开始录")
        row("日历", ok: model.meetings.calendarAccess == .fullAccess, anchor: "Privacy_Calendars")
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
