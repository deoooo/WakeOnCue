import Foundation

// `wakeoncue`: read-only access to WakeOnCue's transcripts and summaries on this Mac, for people
// and for tools such as Claude. Private and deleted time is never shown.

let usage = """
  用法：wakeoncue <命令> [选项]

  命令：
    day [日期]                      当天总结、重点事件和每小时总结
    transcript [日期] [--hour HH | --from HH:MM --to HH:MM]
                                   转录原文
    search <词>... [--days N] [--speaker 我|会议对方|他人]
                                   全文搜索，多个词同时命中的排在前面
    meetings [日期]                 会议列表
    meeting <编号>                  一场会议的要点和完整转录
    export [日期] [--hour HH | --meeting 编号] [--format md|txt|srt]
                                   导出成文件内容，输出到标准输出；默认导出整天的 Markdown
    health [--days N]               检查最近 N 天（默认 3）的全天录音：没有原因的空档、
                                   有音频没转录、有转录没总结、回传进度
    help                           显示这段说明

  日期：今天（默认）、昨天、2026-11-04 或 11-04。
  通用选项：--json 输出 JSON，方便脚本和 AI 工具使用。
  标为私人或已删除的时段不会出现在任何结果里。
  """

struct UsageError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Arguments split into positionals and `--name value` options (`--json` takes no value).
struct Arguments {
  var positionals: [String] = []
  var options: [String: String] = [:]
  var json = false

  init(_ raw: [String]) throws {
    var index = 0
    while index < raw.count {
      let item = raw[index]
      if item == "--json" {
        json = true
      } else if item.hasPrefix("--") {
        guard index + 1 < raw.count else { throw UsageError(message: "\(item) 缺少取值") }
        options[String(item.dropFirst(2))] = raw[index + 1]
        index += 1
      } else {
        positionals.append(item)
      }
      index += 1
    }
  }
}

enum Dates {
  static func day(_ text: String?) throws -> Date {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    guard let text, !text.isEmpty else { return today }
    switch text.lowercased() {
    case "今天", "today": return today
    case "昨天", "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)!
    case "前天": return calendar.date(byAdding: .day, value: -2, to: today)!
    default: break
    }
    let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
    var components = calendar.dateComponents([.year], from: today)
    switch parts.count {
    case 3: (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
    case 2: (components.month, components.day) = (parts[0], parts[1])
    default: throw UsageError(message: "看不懂的日期：\(text)")
    }
    guard let date = calendar.date(from: components) else { throw UsageError(message: "看不懂的日期：\(text)") }
    return date
  }

  static func clock(_ text: String, on day: Date) throws -> Date {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard (1...2).contains(parts.count) else { throw UsageError(message: "看不懂的时间：\(text)") }
    return day.addingTimeInterval(Double(parts[0] * 3_600 + (parts.count > 1 ? parts[1] * 60 : 0)))
  }

  static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter
  }()
}

/// What the commands print, shaped for `--json`.
struct SentenceOut: Encodable {
  let id: Int64
  let start: String
  let end: String
  let speaker: String
  let source: String
  let text: String

  init(_ sentence: Sentence) {
    id = sentence.id
    start = Dates.iso.string(from: sentence.start)
    end = Dates.iso.string(from: sentence.end)
    speaker = sentence.speaker.label
    source = sentence.source
    text = sentence.text
  }

  var line: String { "\(start.dropFirst(11).prefix(8)) \(speaker) · \(source)：\(text)" }
}

struct CitedOut: Encodable {
  let text: String
  let cites: [SentenceOut]
}

struct MeetingOut: Encodable {
  let id: Int64
  let title: String
  let start: String
  let end: String
  let attendees: [String]
  let points: [CitedOut]?
  let transcript: [SentenceOut]?
}

@MainActor
struct Reader {
  let store: Store
  let marks: [TimeMark]

  init() throws {
    guard FileManager.default.fileExists(atPath: Store.rootDirectory.appending(path: "library.sqlite").path) else {
      throw UsageError(message: "还没有 WakeOnCue 的数据。请先打开 WakeOnCue 完成设置。")
    }
    store = try Store(readOnly: true)
    marks = store.marks()
  }

  func visible(_ date: Date) -> Bool { !marks.contains { $0.covers(date) } }

  func sentences(in interval: DateInterval) -> [Sentence] {
    store.sentences(in: interval).filter { visible($0.start) }
  }

  func cited(_ line: CitedLine) -> CitedOut? {
    let sources = store.sentences(ids: line.cites)
    guard sources.allSatisfy({ visible($0.start) }), !sources.isEmpty || line.cites.isEmpty else { return nil }
    return CitedOut(text: line.text, cites: sources.map(SentenceOut.init))
  }

  func meeting(_ meeting: Meeting, transcript: Bool) -> MeetingOut {
    MeetingOut(
      id: meeting.id, title: meeting.title, start: Dates.iso.string(from: meeting.start), end: Dates.iso.string(from: meeting.end),
      attendees: meeting.attendees.map { person in person.email.map { "\(person.name) <\($0)>" } ?? person.name },
      points: meeting.points.compactMap(cited),
      transcript: transcript ? sentences(in: DateInterval(start: meeting.start, end: max(meeting.end, meeting.start))).map(SentenceOut.init) : nil)
  }
}

func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
  print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func cites(_ out: CitedOut) -> String {
  out.cites.isEmpty ? "" : " [" + out.cites.map { String($0.start.dropFirst(11).prefix(5)) }.joined(separator: ", ") + "]"
}

@MainActor
func run(_ raw: [String]) throws {
  guard let command = raw.first else {
    print(usage)
    return
  }
  let args = try Arguments(Array(raw.dropFirst()))
  switch command {
  case "help", "-h", "--help":
    print(usage)

  case "day":
    let reader = try Reader()
    let day = try Dates.day(args.positionals.first)
    let interval = DateInterval(start: day, duration: 86_400)
    let summary = reader.store.daySummary(for: day)
    let hours = reader.store.hourSummaries(in: interval).values
      .filter { reader.visible($0.hourStart) }.sorted { $0.hourStart < $1.hourStart }
    let meetings = reader.store.meetings(overlapping: interval).filter { reader.visible($0.start) }
    struct DayOut: Encodable {
      let date: String
      let headline: CitedOut?
      let details: [CitedOut]
      let meetings: [MeetingOut]
      let hours: [HourOut]
    }
    struct HourOut: Encodable {
      let hour: String
      let summary: String
      let keySentences: [SentenceOut]
    }
    let out = DayOut(
      date: TimeText.dayFolder(day),
      headline: summary.flatMap { reader.cited($0.headline) },
      details: summary?.details.compactMap(reader.cited) ?? [],
      meetings: meetings.map { reader.meeting($0, transcript: false) },
      hours: hours.map { hour in
        HourOut(
          hour: TimeText.clock(hour.hourStart), summary: hour.summary,
          keySentences: reader.store.sentences(ids: hour.keySentenceIDs).filter { reader.visible($0.start) }.map(SentenceOut.init))
      })
    if args.json { return try printJSON(out) }
    print("\(TimeText.day(day))")
    if let headline = out.headline { print("\n\(headline.text)\(cites(headline))") }
    if !out.details.isEmpty {
      print("\n详情")
      for line in out.details { print("· \(line.text)\(cites(line))") }
    }
    if !out.meetings.isEmpty {
      print("\n重点事件")
      for meeting in out.meetings {
        print("· #\(meeting.id) \(meeting.start.dropFirst(11).prefix(5))–\(meeting.end.dropFirst(11).prefix(5)) \(meeting.title)")
      }
    }
    if !out.hours.isEmpty {
      print("\n每小时")
      for hour in out.hours { print("\(hour.hour)  \(hour.summary)") }
    }
    if summary == nil && out.hours.isEmpty { print("\n这一天还没有总结。可以用 wakeoncue transcript 查看原文。") }

  case "transcript":
    let reader = try Reader()
    let day = try Dates.day(args.positionals.first)
    var interval = DateInterval(start: day, duration: 86_400)
    if let hour = args.options["hour"].flatMap(Int.init) {
      interval = DateInterval(start: day.addingTimeInterval(Double(hour) * 3_600), duration: 3_600)
    } else if let from = args.options["from"] {
      let start = try Dates.clock(from, on: day)
      let end = try args.options["to"].map { try Dates.clock($0, on: day) } ?? day.addingTimeInterval(86_400)
      guard end > start else { throw UsageError(message: "--to 要晚于 --from") }
      interval = DateInterval(start: start, end: end)
    }
    let out = reader.sentences(in: interval).map(SentenceOut.init)
    if args.json { return try printJSON(out) }
    if out.isEmpty { print("这段时间没有转录。") }
    for sentence in out { print(sentence.line) }

  case "search":
    let words = args.positionals
    guard !words.isEmpty else { throw UsageError(message: "请给出要搜索的词，例如：wakeoncue search 告警") }
    let reader = try Reader()
    let days = args.options["days"].flatMap(Int.init) ?? 0
    let since = days > 0 ? Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: .now))! : .distantPast
    let speaker = args.options["speaker"]
    var scored: [Int64: (Sentence, Int)] = [:]
    for word in words {
      for hit in reader.store.search(word, limit: 500)
      where hit.start >= since && reader.visible(hit.start) && (speaker == nil || hit.speaker.label == speaker) {
        scored[hit.id, default: (hit, 0)].1 += 1
      }
    }
    let hits = scored.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.start > $1.0.start }.prefix(100).map(\.0)
    let out = hits.map(SentenceOut.init)
    if args.json { return try printJSON(out) }
    if out.isEmpty { print("没有找到。标为私人或已删除的时段不会出现在结果里。") }
    for sentence in out { print("\(sentence.start.prefix(10)) \(sentence.line)") }

  case "meetings":
    let reader = try Reader()
    let day = try Dates.day(args.positionals.first)
    let out = reader.store.meetings(overlapping: DateInterval(start: day, duration: 86_400))
      .filter { reader.visible($0.start) }.map { reader.meeting($0, transcript: false) }
    if args.json { return try printJSON(out) }
    if out.isEmpty { print("这一天没有会议。") }
    for meeting in out {
      print("#\(meeting.id) \(meeting.start.dropFirst(11).prefix(5))–\(meeting.end.dropFirst(11).prefix(5)) \(meeting.title)")
    }

  case "meeting":
    guard let id = args.positionals.first.flatMap(Int64.init) else { throw UsageError(message: "请给出会议编号，例如：wakeoncue meeting 3") }
    let reader = try Reader()
    guard let meeting = reader.store.meeting(id: id), reader.visible(meeting.start) else { throw UsageError(message: "没有编号为 \(id) 的会议") }
    let out = reader.meeting(meeting, transcript: true)
    if args.json { return try printJSON(out) }
    print("\(out.title)  \(out.start.prefix(10)) \(out.start.dropFirst(11).prefix(5))–\(out.end.dropFirst(11).prefix(5))")
    if !out.attendees.isEmpty { print("参会人：\(out.attendees.joined(separator: "、"))") }
    print("\n要点")
    if out.points?.isEmpty ?? true { print("（还没有生成）") }
    for point in out.points ?? [] { print("· \(point.text)\(cites(point))") }
    print("\n完整转录")
    for sentence in out.transcript ?? [] { print(sentence.line) }

  case "export":
    let reader = try Reader()
    let formatText = args.options["format"] ?? "md"
    guard let format = ExportFormat(rawValue: formatText.lowercased()) else {
      throw UsageError(message: "不支持的格式：\(formatText)，可选 md、txt、srt")
    }
    let source: ExportSource
    if let text = args.options["meeting"] {
      guard let id = Int64(text), let meeting = reader.store.meeting(id: id), reader.visible(meeting.start) else {
        throw UsageError(message: "没有编号为 \(text) 的会议")
      }
      source = .meeting(meeting, store: reader.store)
    } else {
      let day = try Dates.day(args.positionals.first)
      if let text = args.options["hour"] {
        guard let hour = Int(text), (0..<24).contains(hour) else { throw UsageError(message: "--hour 要在 0 到 23 之间") }
        source = .hour(Calendar.current.date(byAdding: .hour, value: hour, to: day)!, store: reader.store)
      } else {
        source = .day(day, store: reader.store)
      }
    }
    if args.json { throw UsageError(message: "export 不支持 --json，请用 --format 选择格式") }
    FileHandle.standardOutput.write(Data(Exporter.render(source, as: format).utf8))

  case "health":
    let reader = try Reader()
    let days = max(1, args.options["days"].flatMap(Int.init) ?? 3)
    let out = healthReport(store: reader.store, days: days)
    if args.json { return try printJSON(out) }
    printHealth(out, remote: reader.store.remoteSegmentCounts())

  default:
    throw UsageError(message: "不认识的命令：\(command)\n\n\(usage)")
  }
}

do {
  try MainActor.assumeIsolated { try run(Array(CommandLine.arguments.dropFirst())) }
} catch let error as UsageError {
  FileHandle.standardError.write(Data((error.message + "\n").utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
