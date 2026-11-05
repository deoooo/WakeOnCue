import Foundation
import Testing

/// The export formatter is pure, so these build sources by hand instead of opening a library.
@MainActor
struct ExportTests {
  let calendar = Calendar.current

  func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
    let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    return base.addingTimeInterval(second)
  }

  func sentence(_ id: Int64, _ start: Date, _ text: String, length: TimeInterval = 3, name: String? = nil) -> Sentence {
    Sentence(
      id: id, start: start, end: start.addingTimeInterval(length), channel: .microphone, speaker: .me,
      source: "Mac 麦克风", text: text, speakerName: name)
  }

  func mark(_ kind: TimeMark.Kind, _ start: Date, _ end: Date) -> TimeMark {
    TimeMark(id: Int64.random(in: 1...9_999), kind: kind, start: start, end: end, createdAt: start)
  }

  /// 09:00 public, 10:00 private, 11:00 deleted, with a day summary citing all three.
  func daySource() -> ExportSource {
    let start = calendar.startOfDay(for: at(5, 12, 0))
    let range = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    let sentences = [
      sentence(1, at(5, 9, 3, 12), "上线前先跑一遍灰度", name: "林雨"),
      sentence(2, at(5, 9, 10), "好的"),
      sentence(3, at(5, 10, 5), "体检报告出来了"),
      sentence(4, at(5, 11, 20), "这段不要了"),
    ]
    let summary = DaySummary(
      day: start, headline: CitedLine(text: "上午定了灰度方案", cites: [1]),
      details: [
        CitedLine(text: "灰度先跑一遍", cites: [1, 2]),
        CitedLine(text: "体检结果", cites: [3]),
        CitedLine(text: "删掉的话", cites: [1, 4]),
      ],
      generatedAt: at(5, 23, 0))
    let hours = [
      HourSummary(hourStart: at(5, 9, 0), summary: "讨论灰度", keySentenceIDs: [1], generatedAt: at(5, 10, 0), isFinal: true),
      HourSummary(hourStart: at(5, 10, 0), summary: "私人小时的总结", keySentenceIDs: [3], generatedAt: at(5, 11, 0), isFinal: true),
      HourSummary(hourStart: at(5, 11, 0), summary: "删除小时的总结", keySentenceIDs: [4], generatedAt: at(5, 12, 0), isFinal: true),
    ]
    let meetings = [
      Meeting(
        id: 1, title: "灰度评审", start: at(5, 9, 0), end: at(5, 9, 30), origin: .manual, attendees: [], points: [],
        userAdjusted: false),
      Meeting(
        id: 2, title: "私人会面", start: at(5, 10, 0), end: at(5, 10, 30), origin: .manual, attendees: [], points: [],
        userAdjusted: false),
    ]
    return ExportSource(
      scope: .day, range: range, sentences: sentences,
      marks: [mark(.privateRange, at(5, 10, 0), at(5, 11, 0)), mark(.deleted, at(5, 11, 0), at(5, 12, 0))],
      daySummary: summary, hourSummaries: hours, meetings: meetings)
  }

  @Test func privateAndDeletedNeverExported() {
    let source = daySource()
    for format in ExportFormat.allCases {
      let out = Exporter.render(source, as: format)
      #expect(out.contains("上线前先跑一遍灰度"), "\(format)")
      for hidden in ["体检报告", "这段不要了", "私人小时的总结", "删除小时的总结", "体检结果", "删掉的话", "私人会面"] {
        #expect(!out.contains(hidden), "\(format) 里出现了 \(hidden)")
      }
    }
  }

  @Test func markdownHasSummariesAndNamedTranscript() {
    let out = Exporter.render(daySource(), as: .markdown)
    #expect(out.contains("## 一句话\n\n上午定了灰度方案（09:03）"))
    #expect(out.contains("- 灰度先跑一遍（09:03、09:10）"))
    #expect(out.contains("- 09:00–09:30 灰度评审"))
    #expect(out.contains("### 09:00–10:00\n\n讨论灰度"))
    #expect(out.contains("- 09:03:12 **林雨**：上线前先跑一遍灰度"))
    #expect(out.contains("- 09:10:00 **我**：好的"))
    // A wholly hidden hour leaves no empty heading behind.
    #expect(!out.contains("### 10:00"))
    #expect(!out.contains("### 11:00"))
  }

  @Test func textIsTranscriptOnly() {
    let out = Exporter.render(daySource(), as: .text)
    #expect(out == "09:03:12 林雨：上线前先跑一遍灰度\n09:10:00 我：好的\n")
  }

  @Test func srtTimesStartAtTheRange() {
    var source = daySource()
    source.scope = .hour
    source.range = DateInterval(start: at(5, 9, 0), duration: 3_600)
    let out = Exporter.render(source, as: .srt)
    #expect(out == """
      1
      00:03:12,000 --> 00:03:15,000
      林雨：上线前先跑一遍灰度

      2
      00:10:00,000 --> 00:10:03,000
      我：好的

      """)
    // Whole-day SRT counts from midnight.
    let day = Exporter.render(daySource(), as: .srt)
    #expect(day.hasPrefix("1\n09:03:12,000 --> 09:03:15,000\n"))
  }

  @Test func srtTimeFormat() {
    #expect(Exporter.srtTime(0) == "00:00:00,000")
    #expect(Exporter.srtTime(3_723.456) == "01:02:03,456")
    #expect(Exporter.srtTime(-5) == "00:00:00,000")
    #expect(Exporter.srtTime(90_000) == "25:00:00,000")
  }

  @Test func meetingAcrossMidnight() {
    let meeting = Meeting(
      id: 7, title: "跨夜发布", start: at(5, 23, 40), end: at(6, 0, 20), origin: .manual,
      attendees: [Attendee(name: "林雨")],
      points: [CitedLine(text: "零点切流", cites: [11]), CitedLine(text: "私下聊的", cites: [12])],
      userAdjusted: false)
    let sentences = [
      sentence(10, at(5, 23, 50), "准备切流"),
      sentence(11, at(6, 0, 5, 0.5), "切了", length: 2),
      sentence(12, at(6, 0, 12), "私下说一句"),
      sentence(13, at(6, 0, 30), "会后的话"),
    ]
    let source = ExportSource(
      scope: .meeting(meeting), range: DateInterval(start: meeting.start, end: meeting.end), sentences: sentences,
      marks: [mark(.privateRange, at(6, 0, 10), at(6, 0, 15))])
    let srt = Exporter.render(source, as: .srt)
    #expect(srt.contains("1\n00:10:00,000 --> 00:10:03,000\n我：准备切流"))
    #expect(srt.contains("2\n00:25:00,500 --> 00:25:02,500\n我：切了"))
    #expect(!srt.contains("私下") && !srt.contains("会后"))

    let markdown = Exporter.render(source, as: .markdown)
    #expect(markdown.contains("23:40–11-6 00:20"))
    #expect(markdown.contains("参会人：林雨"))
    #expect(markdown.contains("- 零点切流（11-6 00:05）"))
    #expect(!markdown.contains("私下"))
    #expect(markdown.contains("- 23:50:00 **我**：准备切流\n- 11-6 00:05:00 **我**：切了"))

    #expect(Exporter.fileName(source, as: .srt) == "WakeOnCue 2026-11-05 跨夜发布.srt")
  }

  @Test func dayRangeEndsAt24() {
    let out = Exporter.render(daySource(), as: .markdown)
    #expect(!out.contains("11-6"))
    var source = daySource()
    source.scope = .hour
    source.range = DateInterval(start: at(5, 23, 0), duration: 3_600)
    source.sentences = [sentence(20, at(5, 23, 59, 58), "最后一句", length: 4)]
    let hour = Exporter.render(source, as: .markdown)
    #expect(hour.contains("23:00–24:00"))
    #expect(Exporter.render(source, as: .srt).contains("00:59:58,000 --> 01:00:02,000"))
    #expect(Exporter.fileName(source, as: .markdown) == "WakeOnCue 2026-11-05 23 点.md")
  }

  @Test func emptyRange() {
    var source = daySource()
    source.marks = [mark(.deleted, source.range.start, source.range.end)]
    #expect(Exporter.render(source, as: .text) == "")
    #expect(Exporter.render(source, as: .srt) == "")
    let markdown = Exporter.render(source, as: .markdown)
    #expect(markdown.contains("这段时间没有可导出的转录。"))
    #expect(!markdown.contains("灰度"))
  }
}
