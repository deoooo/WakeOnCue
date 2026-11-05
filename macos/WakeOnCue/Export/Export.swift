import Foundation

/// What an export is written as.
nonisolated enum ExportFormat: String, CaseIterable, Sendable {
  /// Summaries plus the transcript with times and speakers.
  case markdown = "md"
  /// The transcript alone.
  case text = "txt"
  /// Subtitles, timed from the start of the range exported.
  case srt

  var label: String {
    switch self {
    case .markdown: "Markdown"
    case .text: "纯文本（TXT）"
    case .srt: "字幕（SRT）"
    }
  }
}

/// Everything one export draws on, read from the store as is: private and deleted time is still
/// in here and is taken out by `Exporter`, so no caller can forget it.
nonisolated struct ExportSource: Sendable {
  enum Scope: Hashable, Sendable {
    case day
    case hour
    case meeting(Meeting)
  }

  var scope: Scope
  var range: DateInterval
  /// Sentences that start in the range, hidden ones included.
  var sentences: [Sentence]
  /// Private, deleted and paused ranges that overlap it.
  var marks: [TimeMark]
  var daySummary: DaySummary? = nil
  var hourSummaries: [HourSummary] = []
  var meetings: [Meeting] = []
}

/// Turns an `ExportSource` into Markdown, plain text or SRT. Pure: same input, same text.
nonisolated enum Exporter {
  static func render(_ source: ExportSource, as format: ExportFormat, calendar: Calendar = .current) -> String {
    let view = Visible(source, calendar: calendar)
    switch format {
    case .markdown: return markdown(view)
    case .text: return text(view)
    case .srt: return srt(view)
    }
  }

  /// "WakeOnCue 2026-11-05.md", "WakeOnCue 2026-11-05 09 点.srt", "WakeOnCue 2026-11-05 周会.txt".
  static func fileName(_ source: ExportSource, as format: ExportFormat, calendar: Calendar = .current) -> String {
    let day = TimeText.dayFolder(source.range.start)
    let name: String
    switch source.scope {
    case .day: name = day
    case .hour: name = String(format: "%@ %02d 点", day, calendar.component(.hour, from: source.range.start))
    case .meeting(let meeting):
      let title = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-")
      name = "\(day) \(title)"
    }
    return "WakeOnCue \(name).\(format.rawValue)"
  }

  /// "01:02:03,450".
  static func srtTime(_ offset: TimeInterval) -> String {
    let total = max(0, Int((offset * 1_000).rounded()))
    return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total % 3_600_000 / 60_000, total % 60_000 / 1_000, total % 1_000)
  }

  // MARK: What may be shown

  /// The source with everything private or deleted removed, and summary lines that cite it dropped.
  struct Visible {
    let source: ExportSource
    let calendar: Calendar
    let sentences: [Sentence]
    let byID: [Int64: Sentence]
    let hiddenIDs: Set<Int64>

    init(_ source: ExportSource, calendar: Calendar) {
      self.source = source
      self.calendar = calendar
      let inRange = source.sentences.filter { $0.start >= source.range.start && $0.start < source.range.end }
      let hidden = { (s: Sentence) in source.marks.contains { $0.covers(s.start) } }
      sentences = inRange.filter { !hidden($0) }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
      byID = Dictionary(sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      hiddenIDs = Set(source.sentences.filter(hidden).map(\.id))
    }

    func isHidden(_ date: Date) -> Bool { source.marks.contains { $0.covers(date) } }

    /// A line is kept only when every sentence it cites is still here. Lines that cite nothing
    /// are kept only where `allowUncited` (a headline written from the hours, say).
    func keep(_ line: CitedLine, allowUncited: Bool = false) -> Bool {
      guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      if line.cites.isEmpty { return allowUncited }
      return line.cites.allSatisfy { byID[$0] != nil }
    }

    var headline: CitedLine? {
      guard let line = source.daySummary?.headline, keep(line, allowUncited: true) else { return nil }
      return line
    }

    var details: [CitedLine] { source.daySummary?.details.filter { keep($0) } ?? [] }

    var meetings: [Meeting] {
      source.meetings.filter { !isHidden($0.start) }.sorted { $0.start < $1.start }
    }

    var meetingPoints: [CitedLine] {
      guard case .meeting(let meeting) = source.scope else { return [] }
      return meeting.points.filter { keep($0) }
    }

    /// Hours that have something to show, each with its summary when that is safe to show: an
    /// hour marked private or deleted at its start, or whose key sentences are hidden, has none.
    var hours: [(interval: DateInterval, summary: HourSummary?, sentences: [Sentence])] {
      var starts = Set(sentences.map { calendar.dateInterval(of: .hour, for: $0.start)!.start })
      for summary in source.hourSummaries where source.range.contains(summary.hourStart) { starts.insert(summary.hourStart) }
      return starts.sorted().compactMap { start in
        let interval = calendar.dateInterval(of: .hour, for: start)!
        let inHour = sentences.filter { interval.contains($0.start) && $0.start < interval.end }
        let summary = source.hourSummaries.first { $0.hourStart == start }.flatMap { summary -> HourSummary? in
          guard !isHidden(start), !inHour.isEmpty, !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !summary.keySentenceIDs.contains(where: hiddenIDs.contains)
          else { return nil }
          return summary
        }
        if inHour.isEmpty && summary == nil { return nil }
        return (interval, summary, inHour)
      }
    }

    /// "09:03:12", with the date in front once the range has crossed into another day.
    func clock(_ date: Date, seconds: Bool = true) -> String {
      let time = seconds ? TimeText.seconds(date) : TimeText.clock(date)
      guard !calendar.isDate(date, inSameDayAs: source.range.start) else { return time }
      let parts = calendar.dateComponents([.month, .day], from: date)
      return "\(parts.month!)-\(parts.day!) \(time)"
    }

    /// "09:00–10:00"; a range that ends at the next midnight reads "–24:00".
    func range(_ interval: DateInterval) -> String {
      let end = interval.end == calendar.startOfDay(for: interval.end) && interval.end > interval.start
        && calendar.isDate(interval.end.addingTimeInterval(-1), inSameDayAs: interval.start)
        ? "24:00" : clock(interval.end, seconds: false)
      return "\(clock(interval.start, seconds: false))–\(end)"
    }

    func cites(_ line: CitedLine) -> String {
      var times: [String] = []
      for sentence in line.cites.compactMap({ byID[$0] }).sorted(by: { $0.start < $1.start }) {
        let time = clock(sentence.start, seconds: false)
        if times.last != time { times.append(time) }
      }
      return times.isEmpty ? "" : "（\(times.joined(separator: "、"))）"
    }
  }

  // MARK: Formats

  private static func markdown(_ view: Visible) -> String {
    let source = view.source
    var out: [String] = []
    switch source.scope {
    case .day:
      out.append("# \(TimeText.day(source.range.start))")
    case .hour:
      out.append("# \(TimeText.day(source.range.start)) \(view.range(source.range))")
    case .meeting(let meeting):
      out.append("# \(meeting.title)")
      out.append("")
      var info = "\(TimeText.day(meeting.start)) \(view.range(source.range))"
      if !meeting.attendees.isEmpty { info += " · 参会人：" + meeting.attendees.map(\.name).joined(separator: "、") }
      out.append(info)
    }
    out.append("")
    out.append("> 由 WakeOnCue 导出。标为私人或已删除的时段不包含在内。")

    if case .day = source.scope {
      if let headline = view.headline {
        out += ["", "## 一句话", "", headline.text + view.cites(headline)]
      }
      let details = view.details
      if !details.isEmpty {
        out += ["", "## 详情总结", ""]
        out += details.map { "- \($0.text)\(view.cites($0))" }
      }
      let meetings = view.meetings
      if !meetings.isEmpty {
        out += ["", "## 重点事件", ""]
        out += meetings.map { "- \(view.range(DateInterval(start: $0.start, end: max($0.start, $0.end)))) \($0.title)" }
      }
    }

    if case .meeting = source.scope {
      let points = view.meetingPoints
      if !points.isEmpty {
        out += ["", "## 要点", ""]
        out += points.map { "- \($0.text)\(view.cites($0))" }
      }
      out += ["", "## 完整转录", ""]
      out += view.sentences.map { transcriptItem($0, view) }
    } else {
      let hours = view.hours
      if case .day = source.scope, !hours.isEmpty { out += ["", "## 每小时"] }
      let level = source.scope == .day ? "###" : "##"
      for hour in hours {
        if source.scope == .day { out += ["", "\(level) \(view.range(hour.interval))"] }
        if let summary = hour.summary {
          out += ["", source.scope == .day ? summary.summary : "\(level) 总结\n\n\(summary.summary)"]
        }
        if !hour.sentences.isEmpty {
          if source.scope == .hour { out += ["", "\(level) 转录"] }
          out.append("")
          out += hour.sentences.map { transcriptItem($0, view) }
        }
      }
    }
    if view.sentences.isEmpty { out += ["", "这段时间没有可导出的转录。"] }
    return out.joined(separator: "\n") + "\n"
  }

  private static func transcriptItem(_ sentence: Sentence, _ view: Visible) -> String {
    "- \(view.clock(sentence.start)) **\(sentence.speakerLabel)**：\(sentence.text)"
  }

  private static func text(_ view: Visible) -> String {
    let lines = view.sentences.map { "\(view.clock($0.start)) \($0.speakerLabel)：\($0.text)" }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  private static func srt(_ view: Visible) -> String {
    let origin = view.source.range.start
    let cues = view.sentences.enumerated().map { index, sentence in
      let start = sentence.start.timeIntervalSince(origin)
      // A cue needs a visible length, even for a sentence stored without one.
      let end = max(sentence.end.timeIntervalSince(origin), start + 1)
      return "\(index + 1)\n\(srtTime(start)) --> \(srtTime(end))\n\(sentence.speakerLabel)：\(sentence.text)\n"
    }
    return cues.joined(separator: "\n")
  }
}
