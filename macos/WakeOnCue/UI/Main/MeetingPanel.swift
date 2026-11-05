import AppKit
import SwiftUI

/// A whole meeting: key points with citations, the full transcript (not cut at the hour), and
/// the minutes to send.
struct MeetingPanel: View {
  @Environment(AppModel.self) private var model
  let data: DayData
  @State private var adjusting = false

  var body: some View {
    let _ = model.store.revision
    if let id = model.ui.meetingID, let meeting = model.store.meeting(id: id) {
      VStack(spacing: 0) {
        header(meeting)
        Divider()
        if model.ui.draftingMinutes {
          MinutesDraft(meeting: meeting, sentences: sentences(meeting))
        } else {
          overview(meeting)
        }
      }
      .background(.bar)
      .sheet(isPresented: $adjusting) { AdjustMeeting(meeting: meeting) }
    }
  }

  private func interval(_ meeting: Meeting) -> DateInterval {
    DateInterval(start: meeting.start, end: max(meeting.end, meeting.start))
  }

  private func sentences(_ meeting: Meeting) -> [Sentence] {
    let interval = interval(meeting)
    let hidden = model.store.marks(overlapping: interval)
    return model.store.sentences(in: interval).filter { s in !hidden.contains { $0.covers(s.start) } }
  }

  private func header(_ meeting: Meeting) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.ui.draftingMinutes ? "\(meeting.title) · 发送纪要" : meeting.title)
          .font(.system(size: 16, weight: .semibold))
        Text("\(TimeText.range(meeting.start, meeting.end)) · \(Meetings.sourceText(meeting))")
          .font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Text(Meetings.boundaryText(meeting))
          Button("调整起止…") { adjusting = true }.buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button { model.closeMeeting() } label: { Image(systemName: "xmark") }
        .buttonStyle(.borderless)
        .accessibilityLabel("关闭")
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  private func overview(_ meeting: Meeting) -> some View {
    let rows = sentences(meeting)
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            Text(pointsCaption(meeting)).font(.caption).foregroundStyle(.secondary)
              .padding(.bottom, meeting.pointsGeneratedAt == nil ? 8 : 2)
            RedoStatus(interval: interval(meeting), engine: meeting.pointsGeneratedAt == nil ? .none : .some(meeting.pointsEngine)) {
              model.summaries.regenerateMeeting(meeting.id)
            }
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(meeting.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("•").foregroundStyle(.secondary)
                  CitedText(text: point.text, cites: point.cites.compactMap { byID[$0] }) { id in
                    model.ui.highlighted = id
                    withAnimation { proxy.scrollTo(MainState.sentenceAnchor(id), anchor: .top) }
                  }
                }
              }
            }
            .padding(.bottom, meeting.points.isEmpty && meeting.pointsGeneratedAt != nil ? 6 : 18)
            if meeting.points.isEmpty && meeting.pointsGeneratedAt != nil {
              Text("这段对话里没找到可以列成要点的内容。").font(.callout).foregroundStyle(.secondary).padding(.bottom, 18)
            }
            Text("完整转录 · \(rows.count) 句")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.bottom, 4)
            ForEach(rows) { sentence in
              SentenceRow(sentence: sentence, highlighted: model.ui.highlighted == sentence.id) {
                model.play(sentence)
              }
              .padding(.horizontal, -10)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
        }
      }
      Divider()
      HStack(spacing: 8) {
        Button("在时间线中定位") {
          model.reveal(hour: Calendar.current.hourStart(meeting.start))
        }
        Button("播放整场") { if let first = rows.first { model.play(first) } }
          .disabled(rows.isEmpty)
        Menu("重新…") {
          Button("重新生成要点") { model.summaries.regenerateMeeting(meeting.id) }
            .disabled(model.summaries.engineName == nil || rows.isEmpty)
          Button("重新转录并生成要点") { model.refiner.retranscribe(interval(meeting), summarizeAll: true) }
            .disabled(rows.isEmpty || model.refiner.isRetranscribing(interval(meeting)))
        }
        .fixedSize()
        Spacer()
        Button("发送纪要…") { model.ui.draftingMinutes = true }
          .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  private func pointsCaption(_ meeting: Meeting) -> String {
    if let generated = meeting.pointsGeneratedAt {
      return "要点 · \(meeting.pointsEngine ?? AppleIntelligenceEngine().name)\(TimeText.clock(generated)) 生成"
    }
    if let reason = model.summaries.unavailableReason { return "要点 · \(reason)，没有生成" }
    return meeting.end > .now ? "要点 · 会议结束后几分钟内生成" : "要点 · 正在生成…"
  }
}

/// The minutes preview: recipients from the calendar, editable text, and whether to attach the
/// transcript. Nothing is sent automatically; the user confirms in Mail or the share sheet.
private struct MinutesDraft: View {
  @Environment(AppModel.self) private var model
  let meeting: Meeting
  let sentences: [Sentence]
  @State private var text = ""
  @State private var recipients: [Attendee] = []
  @State private var withTranscript = false
  @State private var adding = false
  @State private var newRecipient = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
              Text("收件人").foregroundStyle(.secondary)
              FlowLayout(spacing: 6) {
                ForEach(recipients, id: \.self) { person in
                  HStack(spacing: 4) {
                    Text(person.name)
                    Button {
                      recipients.removeAll { $0 == person }
                    } label: { Image(systemName: "xmark").font(.caption2) }
                      .buttonStyle(.borderless)
                      .accessibilityLabel("移除 \(person.name)")
                  }
                  .font(.caption)
                  .padding(.leading, 9)
                  .padding(.trailing, 4)
                  .frame(height: 24)
                  .background(Capsule().strokeBorder(.separator))
                }
                Button("添加…") { adding = true }
                  .buttonStyle(.link)
                  .font(.caption)
                  .popover(isPresented: $adding) {
                    TextField("名字或邮箱", text: $newRecipient)
                      .frame(width: 220)
                      .padding(12)
                      .onSubmit(addRecipient)
                  }
              }
            }
            GridRow {
              Text("范围").foregroundStyle(.secondary)
              Text("只包含 \(TimeText.range(meeting.start, meeting.end)) 会议内的内容，会前会后的对话不会带上")
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .font(.callout)
          Text("纪要（可直接修改）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          TextEditor(text: $text)
            .font(.system(size: 14))
            .frame(minHeight: 220)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .onChange(of: text) { model.meetings.saveMinutes(meeting.id, text: text) }
          Toggle(isOn: $withTranscript) {
            VStack(alignment: .leading, spacing: 2) {
              Text("附上完整转录")
              if withTranscript {
                Text("会把所有参会人的原话一起发出去，发送前请确认他们同意。")
                  .font(.caption)
                  .foregroundStyle(Color.recording)
              }
            }
          }
          .toggleStyle(.checkbox)
          Text("不会自动发出。点发送后会打开邮件或分享面板，由你最后确认；发到飞书群可用“复制为富文本”。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
      }
      Divider()
      HStack(spacing: 8) {
        Button("返回") { model.ui.draftingMinutes = false }
        Spacer()
        Button("复制为富文本") { MinutesExport.copyRichText(body: fullText, title: meeting.title) }
        ShareLink(item: fullText, subject: Text(subject)) { Text("分享…") }
        Button("用邮件发送") {
          MinutesExport.email(to: recipients.compactMap(\.email), subject: subject, body: fullText)
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
    .onAppear {
      text = meeting.minutes ?? Meetings.minutes(for: meeting)
      recipients = meeting.attendees
    }
  }

  private var subject: String { "\(meeting.title)纪要" }

  private var fullText: String {
    guard withTranscript else { return text }
    let transcript = sentences.map { "\(TimeText.seconds($0.start)) \($0.speakerLabel)：\($0.text)" }
    return text + "\n\n完整转录\n" + transcript.joined(separator: "\n")
  }

  private func addRecipient() {
    let value = newRecipient.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return }
    recipients.append(Attendee(name: value, email: value.contains("@") ? value : nil))
    newRecipient = ""
    adding = false
  }
}

enum MinutesExport {
  /// Puts the minutes on the pasteboard as RTF and HTML (with plain text as a fallback), so
  /// pasting into Feishu or Mail keeps the heading and bullets.
  static func copyRichText(body: String, title: String) {
    let lines = body.components(separatedBy: "\n")
    let rich = NSMutableAttributedString()
    var html = "<meta charset=\"utf-8\">"
    for (index, line) in lines.enumerated() {
      let isHeading = index == 0 || line == "要点" || line == "完整转录"
      let font = isHeading ? NSFont.boldSystemFont(ofSize: index == 0 ? 15 : 13) : NSFont.systemFont(ofSize: 13)
      rich.append(NSAttributedString(string: line + "\n", attributes: [.font: font]))
      let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      if line.hasPrefix("· ") {
        html += "<li>\(escaped.dropFirst(2))</li>"
      } else if line.isEmpty {
        html += "<br>"
      } else {
        html += isHeading ? "<p><b>\(escaped)</b></p>" : "<p>\(escaped)</p>"
      }
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
      pasteboard.setData(rtf, forType: .rtf)
    }
    pasteboard.setString(html, forType: .html)
    pasteboard.setString(body, forType: .string)
  }

  static func email(to recipients: [String], subject: String, body: String) {
    guard let service = NSSharingService(named: .composeEmail) else { return }
    service.recipients = recipients
    service.subject = subject
    service.perform(withItems: [body])
  }
}

/// Moves a meeting's start and end, or renames it.
private struct AdjustMeeting: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let meeting: Meeting
  @State private var title = ""
  @State private var start = Date()
  @State private var end = Date()

  var body: some View {
    Form {
      TextField("名称", text: $title)
      DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
      DatePicker("结束", selection: $end, in: start..., displayedComponents: .hourAndMinute)
      Text("调整后会重新生成要点。").font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 340)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          model.meetings.adjust(meeting.id, title: title, start: start, end: end)
          dismiss()
        }
      }
    }
    .onAppear {
      title = meeting.title
      start = meeting.start
      end = meeting.end
    }
  }
}
