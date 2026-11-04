import SwiftUI

/// The main window: one page per day, the calendar sidebar, the meeting panel as an inspector
/// (it overlays the content when the window is narrow) and the player along the bottom.
struct MainWindow: View {
  @Environment(AppModel.self) private var model
  @FocusState private var searchFocused: Bool
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var ui = model.ui
    let _ = model.store.revision
    let data = DayData.load(day: ui.day, store: model.store)
    NavigationSplitView {
      Sidebar().navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
    } detail: {
      VStack(spacing: 0) {
        GeometryReader { geometry in
          // Side by side when there is room; over the content when the window is narrow.
          let overlay = geometry.size.width < 760
          HStack(spacing: 0) {
            page(data).frame(maxWidth: .infinity, maxHeight: .infinity)
            if panelShown && !overlay {
              Divider()
              sidePanel(data).frame(width: 400)
            }
          }
          .overlay(alignment: .trailing) {
            if panelShown && overlay {
              sidePanel(data)
                .frame(width: min(400, geometry.size.width - 40))
                .background(.background)
                .shadow(color: .black.opacity(0.18), radius: 16)
            }
          }
        }
        if ui.showTracks && ui.page == .day {
          Divider()
          TracksBar(data: data)
        }
      }

    }
    .navigationTitle(title)
    .navigationSubtitle(subtitle(data))
    .toolbar { toolbar }
    .searchable(text: $ui.searchText, placement: .toolbar, prompt: "搜索全部录音 ⌘F")
    .searchFocused($searchFocused)
    .onSubmit(of: .search) { ui.submittedSearch = ui.searchText }
    .frame(minWidth: 900, minHeight: 600)
    .onChange(of: ui.focusSearch) { searchFocused = true }
    .background(WindowSizer())
    .onAppear { model.openSettings = { openSettings() } }
    .sheet(isPresented: .constant(!model.preferences.onboarded)) { OnboardingView() }
    .onChange(of: ui.searchText) {
      ui.page = ui.searchText.trimmingCharacters(in: .whitespaces).isEmpty ? .day : .search
    }
  }

  private var meetingShown: Bool { model.ui.meetingID != nil && model.ui.page == .day }
  private var panelShown: Bool { meetingShown || model.ui.asking }

  @ViewBuilder private func sidePanel(_ data: DayData) -> some View {
    if model.ui.asking {
      AskPanel()
    } else {
      MeetingPanel(data: data)
    }
  }

  @ViewBuilder private func page(_ data: DayData) -> some View {
    switch model.ui.page {
    case .day: DayPage(data: data)
    case .search: SearchPage()
    case .deleted: DeletedPage()
    }
  }

  private var title: String {
    switch model.ui.page {
    case .search: "搜索"
    case .deleted: "最近删除"
    case .day: model.ui.isToday ? "今天" : TimeText.relativeDay(model.ui.day)
    }
  }

  private func subtitle(_ data: DayData) -> String {
    guard model.ui.page == .day else { return "" }
    return TimeText.day(data.day) + " · 已录 " + TimeText.duration(data.recordedSeconds)
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button { model.ui.moveDay(by: -1) } label: { Image(systemName: "chevron.left") }
        .help("前一天（⌘[）")
      Button("今天") { model.ui.show(day: .now) }
        .help("回到今天（⌘T）")
        .disabled(model.ui.isToday && model.ui.page == .day)
      Button { model.ui.moveDay(by: 1) } label: { Image(systemName: "chevron.right") }
        .help("后一天（⌘]）")
        .disabled(model.ui.isToday)
    }
    ToolbarItem(placement: .primaryAction) { StatusPill() }
    ToolbarItem(placement: .primaryAction) {
      Button(model.recorder.isRecording ? "暂停" : "继续") {
        Task { await model.recorder.togglePause() }
      }
      .help("暂停或继续（⌃⌥P）")
      .disabled(model.recorder.state == .off && !model.preferences.onboarded)
    }
    ToolbarItem(placement: .primaryAction) {
      Toggle(isOn: Bindable(model.ui).asking) {
        Label("提问", systemImage: "bubble.left.and.text.bubble.right")
      }
      .help("问问你的录音（⌘K）")
      .keyboardShortcut("k")
    }
    ToolbarItem(placement: .primaryAction) {
      Toggle(isOn: Bindable(model.ui).showTracks) {
        HStack(spacing: 6) {
          Image(systemName: "waveform")
          Text("音轨")
          if model.player.isPlaying && !model.ui.showTracks, let position = model.player.position {
            Text("播放中 \(TimeText.seconds(position))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
          }
        }
      }
      .help("显示音轨和回放")
    }
  }
}

/// "录音中 · 内建麦克风 · 飞书", or why it is not recording.
struct StatusPill: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let status = model.recordingStatus
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: status.isProblem ? 2 : 4)
        .fill(status.isProblem || model.recorder.isRecording ? Color.recording : .secondary)
        .frame(width: 8, height: 8)
      Text(status.title).fontWeight(.semibold)
      Text(status.detail).foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 26)
    .background(Capsule().fill(status.isProblem ? Color.warningBackground : Color.soft))
    .fixedSize()
  }
}

/// Opens the window at a comfortable size the first time; SwiftUI otherwise starts at the minimum.
private struct WindowSizer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window, window.frame.width < 960, let screen = window.screen?.visibleFrame else { return }
      let size = NSSize(width: min(1240, screen.width - 80), height: min(820, screen.height - 60))
      window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
