import SwiftUI

/// Speech per hour on a 0–24 axis. Bar height is minutes of speech; the share that belongs to a
/// key event is drawn in the event colour. Empty states follow the design's legend.
struct ActivityChart: View {
  @Environment(AppModel.self) private var model
  let data: DayData

  var body: some View {
    @Bindable var ui = model.ui
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("每小时").font(.system(size: 15, weight: .semibold))
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2).fill(Color.event).frame(width: 12, height: 8)
          Text("重点事件")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        Button {
          ui.showLegend.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("图例")
        .popover(isPresented: $ui.showLegend, arrowEdge: .bottom) { Legend() }
      }
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(data.hours) { hour in
          bar(hour)
        }
      }
      .frame(height: 44)
      HStack {
        ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
          Text(label)
          if label != "24" { Spacer() }
        }
      }
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(.secondary)
    }
  }

  private var maxMinutes: Double { max(42, data.hours.map(\.speechMinutes).max() ?? 0) }

  @ViewBuilder private func bar(_ hour: DayData.Hour) -> some View {
    let focused = model.player.isPlaying && model.player.position.map(hour.interval.contains) == true
    let base = focused ? Color.primary : Color.activity
    Button {
      model.reveal(hour: hour.interval.start)
    } label: {
      Group {
        switch hour.state {
        case .speech:
          let height = max(8, hour.speechMinutes / maxMinutes * 44)
          VStack(spacing: 0) {
            Rectangle().fill(base).frame(height: height * (1 - hour.meetingShare))
            Rectangle().fill(Color.event).frame(height: height * hour.meetingShare)
          }
          .clipShape(RoundedRectangle(cornerRadius: 4))
        case .quiet:
          RoundedRectangle(cornerRadius: 2).fill(Color.emptyBar).frame(height: 4)
        case .privateHour:
          Hatch().stroke(Color.hatch, lineWidth: 2).frame(height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
        case .deleted:
          RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .foregroundStyle(.secondary).frame(height: 10)
        case .none, .gap:
          Line().stroke(Color.hatch, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(height: 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .bottom)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(hour.state != .speech)
    .help(label(hour))
    .accessibilityLabel(label(hour))
  }

  private func label(_ hour: DayData.Hour) -> String {
    let range = String(format: "%02d:00–%02d:59，", hour.hour, hour.hour)
    let state: String =
      switch hour.state {
      case .speech: "有人说话约 \(Int(hour.speechMinutes.rounded())) 分钟"
        + (hour.meetings.isEmpty ? "" : "，含" + hour.meetings.map(\.title).joined(separator: "、"))
      case .quiet: "录了，但没人说话"
      case .privateHour: "已标为私人"
      case .deleted: "已删除"
      case .gap(let text): text
      case .none: "没录音"
      }
    return range + state
  }
}

nonisolated private struct Line: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    }
  }
}

private struct Legend: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      key(RoundedRectangle(cornerRadius: 2).fill(Color.activity), "有人说话，高度是说话时长")
      key(RoundedRectangle(cornerRadius: 2).fill(Color.event), "其中属于重点事件的部分")
      key(RoundedRectangle(cornerRadius: 2).fill(Color.emptyBar).frame(height: 4), "录了，没人说话")
      key(Line().stroke(Color.hatch, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(height: 2), "没录音")
      key(Hatch(spacing: 4).stroke(Color.hatch, lineWidth: 1.5).clipShape(Rectangle()), "已标为私人")
      key(RoundedRectangle(cornerRadius: 2).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2])).foregroundStyle(.secondary), "已删除")
    }
    .font(.caption)
    .padding(12)
    .frame(width: 230, alignment: .leading)
  }

  private func key(_ swatch: some View, _ text: String) -> some View {
    HStack(spacing: 6) {
      swatch.frame(width: 12, height: 8)
      Text(text)
    }
  }
}

/// One hour: its summary (or why there is none), the meeting it belongs to, an in-place
/// transcript that opens on the key sentences, and the "…" menu.
struct HourRow: View {
  @Environment(AppModel.self) private var model
  let hour: DayData.Hour
  let data: DayData

  private var expanded: Bool { model.ui.expandedHours.contains(hour.interval.start) && hour.state == .speech }
  private var focused: Bool {
    model.player.isPlaying && model.player.position.map(hour.interval.contains) == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
      HStack(alignment: .top, spacing: 12) {
        Text(hour.clock)
          .font(.system(size: 15, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(hour.state == .speech ? .primary : .secondary)
          .frame(width: 64, alignment: .leading)
          .padding(.top, 1)
        content.frame(maxWidth: .infinity, alignment: .leading)
        menu
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 10)
      .background(RoundedRectangle(cornerRadius: 8).fill(focused && hour.state == .speech ? Color.soft : .clear))
      .padding(.vertical, 4)
      if expanded { transcript }
    }
  }

  @ViewBuilder private var content: some View {
    switch hour.state {
    case .speech:
      VStack(alignment: .leading, spacing: 4) {
        ForEach(hour.meetings) { meeting in
          Button {
            model.openMeeting(meeting.id)
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(meeting.title + (meeting.start < hour.interval.start ? "（续）" : ""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.event)
              Text(TimeText.range(meeting.start, meeting.end) + " ›")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .help("打开整场：要点、完整转录和纪要")
        }
        Button {
          toggle()
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(summaryText)
              .font(.system(size: 14))
              .lineSpacing(3)
              .foregroundStyle(hour.summary == nil ? .secondary : .primary)
              .multilineTextAlignment(.leading)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text(expanded ? "收起原文" : "展开原文").font(.caption).foregroundStyle(.tint)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已收起")
      }
    case .quiet:
      Text("录了，但这一小时没人说话，没有总结。").font(.callout).foregroundStyle(.secondary)
    case .none:
      Text("这一小时没有录音。").font(.callout).foregroundStyle(.secondary)
    case .gap(let text):
      Text(text).font(.callout).foregroundStyle(Color.recording)
    case .privateHour:
      HStack(spacing: 10) {
        Image(systemName: "lock")
        Text("已标为私人。这一小时不做总结，不能回放，也不会出现在搜索里。")
        Button("取消私人") { model.setPrivate(hour.interval, false) }.buttonStyle(.link)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    case .deleted:
      HStack(spacing: 10) {
        Text("已删除，30 天内可在最近删除中恢复。")
        Button("撤销") { model.undoDelete(hour.interval) }.buttonStyle(.link)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private var summaryText: String {
    if let summary = hour.summary, !summary.summary.isEmpty { return summary.summary }
    return model.summaries.hourPlaceholder(for: hour)
  }

  private var note: String? {
    hour.isCurrent ? "这一小时还没结束，结束后补全总结。" : nil
  }

  private func toggle() {
    let start = hour.interval.start
    if model.ui.expandedHours.contains(start) {
      model.ui.expandedHours.remove(start)
    } else {
      model.ui.expandedHours.insert(start)
    }
  }

  @ViewBuilder private var menu: some View {
    Menu {
      if hour.state == .speech {
        Button("播放这一小时") {
          if let first = hour.sentences.first { model.play(first) }
        }
        if hour.meetings.isEmpty {
          Button("标成一场会议…") { model.markMeeting(in: hour.interval) }
        }
        Button("重新生成总结") { model.summaries.regenerate(hour: hour.interval.start) }
          .disabled(model.summaries.engineName == nil)
        if let asr = model.models.active {
          Button("用 \(asr.name) 重新转录") { model.refiner.retranscribe(hour.interval) }
        }
      }
      if hour.state == .speech || hour.state == .privateHour {
        Button(hour.state == .privateHour ? "取消私人" : "标为私人") {
          model.setPrivate(hour.interval, hour.state != .privateHour)
        }
      }
      if hour.state != .deleted {
        Divider()
        Button("删除这一小时…") {
          model.confirmDelete(
            hour.interval, spokenMinutes: Int(hour.speechMinutes.rounded()),
            title: String(format: "%02d:00–%02d:59", hour.hour, hour.hour))
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: 28)
    .help("更多操作")
    .accessibilityLabel("\(hour.clock) 的更多操作")
  }

  /// Opens on the key sentences; "show all" reveals the rest of the hour.
  @ViewBuilder private var transcript: some View {
    let showAll = model.ui.fullHours.contains(hour.interval.start) || hour.keySentences.isEmpty
    let shown = showAll ? hour.sentences : hour.keySentences
    VStack(alignment: .leading, spacing: 0) {
      ForEach(shown) { sentence in
        SentenceRow(sentence: sentence, highlighted: model.ui.highlighted == sentence.id) {
          model.play(sentence)
        }
      }
      if !showAll {
        Button("显示全部 \(hour.sentences.count) 句") {
          model.ui.fullHours.insert(hour.interval.start)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.leading, 12)
        .padding(.top, 4)
      }
    }
    .padding(.leading, 10)
    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
    .padding(.leading, 76)
    .padding(.bottom, 8)
  }
}
