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
    return ExportSource(
      scope: .day, range: range, sentences: sentences,
      marks: [mark(.privateRange, at(5, 10, 0), at(5, 11, 0)), mark(.deleted, at(5, 11, 0), at(5, 12, 0))],
      daySummary: summary, hourSummaries: hours)
  }

  @Test func privateAndDeletedNeverExported() {
    let source = daySource()
    for format in ExportFormat.allCases {
      let out = Exporter.render(source, as: format)
      #expect(out.contains("上线前先跑一遍灰度"), "\(format)")
      for hidden in ["体检报告", "这段不要了", "私人小时的总结", "删除小时的总结", "体检结果", "删掉的话"] {
        #expect(!out.contains(hidden), "\(format) 里出现了 \(hidden)")
      }
    }
  }

  @Test func markdownHasSummariesAndNamedTranscript() {
    let out = Exporter.render(daySource(), as: .markdown)
    #expect(out.contains("## 一句话\n\n上午定了灰度方案（09:03）"))
    #expect(out.contains("- 灰度先跑一遍（09:03、09:10）"))
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
