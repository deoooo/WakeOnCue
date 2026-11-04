import SwiftUI

/// One day: the summary on top, then key events, the activity chart and every hour.
struct DayPage: View {
  @Environment(AppModel.self) private var model
  let data: DayData

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          IssueBanner()
          headline
          HStack(alignment: .top, spacing: 36) {
            details.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading).layoutPriority(2)
            events.frame(minWidth: 180, maxWidth: 280, alignment: .leading)
          }
          .padding(.top, 26)
          .padding(.horizontal, 4)
          ActivityChart(data: data)
            .padding(.top, 34)
            .padding(.horizontal, 4)
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(data.rows) { hour in
              HourRow(hour: hour, data: data).id(MainState.hourAnchor(hour.interval.start))
            }
          }
          .padding(.top, 10)
          if data.rows.isEmpty {
            Text(data.day > .now ? "" : "这一天没有录音。")
              .foregroundStyle(.secondary)
              .padding(.top, 20)
          }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 28)
      }
      .onChange(of: model.ui.scrollRequest) {
        guard let target = model.ui.scrollTarget else { return }
        // Expanding an hour changes the layout; scroll once it has rendered.
        Task {
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
        }
      }
    }
  }

  @ViewBuilder private var headline: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(model.ui.isToday ? "今天一句话" : "这一天一句话").fontWeight(.semibold)
        Spacer()
        if let summary = data.summary {
          let local = summary.engine == nil || summary.engine == AppleIntelligenceEngine().name
          Text(Summaries.credit(engine: summary.engine, at: summary.generatedAt))
            .help(local ? "总结在这台 Mac 上生成，没有上传" : "总结由网关生成，转录文字发送到了该网关")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let summary = data.summary, !summary.headline.text.isEmpty {
        CitedText(
          text: summary.headline.text, cites: data.headlineCites.compactMap(data.sentence),
          font: .system(size: 20, weight: .semibold)
        ) { model.cite($0) }
      } else {
        Text(model.summaries.dayPlaceholder(for: data))
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      if let destination = model.summaries.destination {
        Label("总结由网关生成，转录文字会发送到 \(destination)。标为私人或已删除的时段不会发送。", systemImage: "arrow.up.forward.app")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
      }
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.hero))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
  }

  @ViewBuilder private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("详情总结").font(.system(size: 15, weight: .semibold))
      if data.visibleDetails.isEmpty {
        Text("有了每小时的总结后，这里会列出当天的要点。").font(.callout).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(data.visibleDetails.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("•").foregroundStyle(.secondary)
              CitedText(text: line.text, cites: line.cites.compactMap(data.sentence)) { model.cite($0) }
            }
          }
        }
      }
      Text("点时间可查看原话。标为私人或已删除的时段不进总结。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var events: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("重点事件").font(.system(size: 15, weight: .semibold))
      if data.meetings.isEmpty {
        Text("会议和标成会议的对话会列在这里。").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(data.meetings) { meeting in
        Button {
          model.openMeeting(meeting.id)
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(TimeText.range(meeting.start, meeting.end)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(meeting.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(model.ui.meetingID == meeting.id ? Color.soft : .clear)
          .overlay(alignment: .leading) { Rectangle().fill(Color.event).frame(width: 3) }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开整场：要点、完整转录和纪要")
      }
    }
  }
}

/// Shown when this Mac cannot record, with the same reason as the menu bar and a way to fix it.
struct IssueBanner: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let issue = model.currentIssue {
      HStack(spacing: 14) {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.recording)
        (Text(issue.title + "。").fontWeight(.semibold) + Text(issue.detail))
          .frame(maxWidth: .infinity, alignment: .leading)
        if let action = issue.action {
          Button(action.title) { action.run() }
        }
      }
      .font(.callout)
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.warningBackground))
      .padding(.bottom, 16)
      .accessibilityElement(children: .contain)
    }
  }
}
