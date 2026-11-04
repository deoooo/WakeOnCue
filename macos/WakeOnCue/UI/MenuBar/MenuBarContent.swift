import SwiftUI

/// The menu bar window: recording state with levels and the latest line, pause and delete,
/// or why it cannot record and how to fix it.
struct MenuBarContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch model.recorder.state {
      case .recording: recording
      case .paused(let until): paused(until)
      case .unavailable(let reason): unavailable(reason)
      case .off: off
      }
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        row("打开 WakeOnCue", shortcut: "⌘O") {
          openWindow(id: "main")
          NSApp.activate()
        }
        row("设置…", shortcut: "⌘,") {
          openSettings()
          NSApp.activate()
        }
        row("退出 WakeOnCue", shortcut: "⌘Q") { NSApp.terminate(nil) }
      }
    }
    .padding(12)
    .frame(width: 290)
  }

  private var recording: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle().fill(Color.recording).frame(width: 9, height: 9)
        Text("录音中").fontWeight(.semibold)
        Spacer()
        Text("今天 \(TimeText.duration(model.todayRecordedSeconds))").font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Text(model.preferences.microphone == .builtIn ? "内建麦克风" : model.recorder.microphoneName)
        Meter(level: model.recorder.microphoneLevel)
        if !model.recorder.activeMeetingApps.isEmpty {
          Text(model.recorder.activeMeetingApps.joined(separator: "、"))
          Meter(level: model.recorder.meetingLevel)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let live = model.transcription.live.values.max(by: { $0.start < $1.start }) {
        Text(live.text).font(.callout).lineLimit(2).foregroundStyle(.secondary)
      } else if let last = model.transcription.lastSentence {
        Text("\(last.speakerLabel)：\(last.text)").font(.callout).lineLimit(2).foregroundStyle(.secondary)
      }
      if let issue = model.currentIssue {
        Text("\(issue.title)。\(issue.detail)").font(.caption).foregroundStyle(Color.recording)
      }
      Button {
        model.recorder.pause(until: .distantFuture)
      } label: {
        Text("暂停").frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .keyboardShortcut("p", modifiers: [.control, .option])
      VStack(alignment: .leading, spacing: 0) {
        row("暂停 1 小时") { model.recorder.pause(until: .now.addingTimeInterval(3_600)) }
        Menu {
          ForEach([5, 15, 30, 60], id: \.self) { minutes in
            Button("刚才 \(minutes) 分钟") { model.deleteRecent(minutes: minutes) }
          }
        } label: {
          Text("删除刚才的录音…")
        }
        .menuStyle(.borderlessButton)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
      }
    }
  }

  private func paused(_ until: Date) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 9, height: 9)
        Text("已暂停").fontWeight(.semibold)
        Spacer()
        Text(until == .distantFuture ? "手动继续" : "\(TimeText.clock(until)) 自动继续").font(.caption).foregroundStyle(.secondary)
      }
      Text("这段时间不录音，也不会出现在时间线上。").font(.callout).foregroundStyle(.secondary)
      Button {
        Task { await model.recorder.resume() }
      } label: {
        Text("继续录音").frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .buttonStyle(.borderedProminent)
      VStack(alignment: .leading, spacing: 0) {
        row("再暂停 1 小时") {
          let base = until == .distantFuture ? Date.now : until
          model.recorder.pause(until: base.addingTimeInterval(3_600))
        }
        row("暂停到明天") {
          let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
          model.recorder.pause(until: tomorrow.addingTimeInterval(8 * 3_600))
        }
      }
    }
  }

  private func unavailable(_ reason: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.recording)
        Text("没有在录音").fontWeight(.semibold)
      }
      if let issue = model.currentIssue {
        VStack(alignment: .leading, spacing: 4) {
          Text(issue.title).fontWeight(.semibold)
          Text(issue.detail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.warningBackground))
        if let action = issue.action {
          Button {
            action.run()
          } label: {
            Text(action.title).frame(maxWidth: .infinity)
          }
          .controlSize(.large)
          .buttonStyle(.borderedProminent)
        }
      }
    }
  }

  private var off: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("没有在录音").fontWeight(.semibold)
      Text(model.preferences.onboarded ? "全天录音已关闭。" : "完成首次设置后开始录音。").font(.callout).foregroundStyle(.secondary)
      if model.preferences.onboarded {
        Button {
          model.preferences.alwaysRecord = true
          Task { await model.recorder.startIfAllowed() }
        } label: {
          Text("开始录音").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
      }
    }
  }

  private func row(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct Meter: View {
  let level: Float

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.soft)
        Capsule().fill(Color.sourceMac).frame(width: geometry.size.width * CGFloat(min(1, level)))
      }
    }
    .frame(width: 44, height: 4)
    .accessibilityLabel("电平约 \(Int(level * 100))%")
  }
}

/// The menu bar icon: a dot while recording, a pause sign when paused, a warning when it cannot.
struct MenuBarIcon: View {
  let state: Recorder.State

  var body: some View {
    switch state {
    case .recording: Image(systemName: "waveform.circle.fill")
    case .paused: Image(systemName: "pause.circle")
    case .unavailable: Image(systemName: "exclamationmark.triangle")
    case .off: Image(systemName: "waveform.circle")
    }
  }
}
