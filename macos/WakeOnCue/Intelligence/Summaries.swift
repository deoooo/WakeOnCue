import Foundation
import FoundationModels
import Observation
import OSLog

/// Hour, day and meeting summaries with Apple Intelligence on this Mac. Each finished hour gets
/// its summary and key sentences; the running hour gets a provisional one every 15 minutes; the
/// day summary follows the hours. Private and deleted ranges never reach the model.
@Observable
final class Summaries {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Summaries")
  /// Characters of transcript per request, to stay well inside the on-device context window.
  private static let partCharacters = 1_800

  /// Why summaries cannot be generated, or nil when Apple Intelligence is ready.
  private(set) var unavailableReason: String?
  private(set) var isWorking = false

  @ObservationIgnored private let store: Store
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var queue: [Job] = []
  @ObservationIgnored private var running = false
  @ObservationIgnored private var failed: Set<Date> = []
  @ObservationIgnored private var provisionalAt: [Date: (time: Date, count: Int)] = [:]
  @ObservationIgnored private var dirtyDays: Set<Date> = []
  /// Meetings ask here for their key points once they end.
  @ObservationIgnored var meetingEnded: ((Meeting) -> Void)?

  private enum Job: Equatable {
    case hour(Date, final: Bool)
    case day(Date)
    case meeting(Int64)
  }

  init(store: Store) {
    self.store = store
    refreshAvailability()
  }

  func start() {
    refreshAvailability()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        self?.refreshAvailability()
        self?.scan()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private func refreshAvailability() {
    switch SystemLanguageModel.default.availability {
    case .available: unavailableReason = nil
    case .unavailable(.deviceNotEligible): unavailableReason = "这台 Mac 不支持 Apple 智能"
    case .unavailable(.appleIntelligenceNotEnabled): unavailableReason = "Apple 智能没有打开"
    case .unavailable(.modelNotReady): unavailableReason = "Apple 智能还在准备中"
    case .unavailable: unavailableReason = "Apple 智能现在不可用"
    }
  }

  // MARK: Placeholders

  func dayPlaceholder(for data: DayData) -> String {
    if let reason = unavailableReason { return "\(reason)，没有生成当天总结。" }
    return data.rows.contains { $0.state == .speech } ? "第一个小时结束后会生成当天总结。" : "这一天还没有人说话。"
  }

  func hourPlaceholder(for hour: DayData.Hour) -> String {
    if let reason = unavailableReason { return "\(reason)，这一小时没有总结。展开原文可查看转录。" }
    if failed.contains(hour.interval.start) { return "这一小时没能生成总结。展开原文可查看转录。" }
    return hour.isCurrent ? "正在听，稍后给出这一小时的临时总结。" : "正在生成这一小时的总结…"
  }

  // MARK: Scheduling

  /// Something changed in this range (marked private, deleted, restored): redo what it touches.
  func invalidate(_ interval: DateInterval) {
    let calendar = Calendar.current
    var hour = calendar.hourStart(interval.start)
    while hour < interval.end {
      failed.remove(hour)
      enqueue(.hour(hour, final: !DateInterval(start: hour, duration: 3_600).contains(.now)))
      hour = hour.addingTimeInterval(3_600)
    }
    enqueue(.day(calendar.startOfDay(for: interval.start)))
  }

  func regenerateMeeting(_ id: Int64) {
    enqueue(.meeting(id))
  }

  /// Finished hours without a final summary, and the running hour every 15 minutes.
  private func scan() {
    guard unavailableReason == nil else { return }
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let window = DateInterval(start: today.addingTimeInterval(-86_400), end: now)
    let summaries = store.hourSummaries(in: window)
    let hidden = store.marks(overlapping: window)
    let sentences = store.sentences(in: window).filter { s in !hidden.contains { $0.covers(s.start) } }
    let byHour = Dictionary(grouping: sentences) { calendar.hourStart($0.start) }
    for (hour, list) in byHour.sorted(by: { $0.key < $1.key }) where !failed.contains(hour) {
      let finished = hour.addingTimeInterval(3_600) <= now
      if finished {
        if summaries[hour]?.isFinal != true { enqueue(.hour(hour, final: true)) }
      } else if list.count >= 5 {
        let last = provisionalAt[hour]
        if last == nil || (now.timeIntervalSince(last!.time) >= 900 && list.count > last!.count) {
          provisionalAt[hour] = (now, list.count)
          enqueue(.hour(hour, final: false))
        }
      }
    }
  }

  private func enqueue(_ job: Job) {
    guard !queue.contains(job) else { return }
    queue.append(job)
    guard !running else { return }
    running = true
    Task { await drain() }
  }

  private func drain() async {
    isWorking = true
    while !queue.isEmpty {
      let job = queue.removeFirst()
      guard unavailableReason == nil else { continue }
      do {
        switch job {
        case .hour(let hour, let final):
          try await summarizeHour(hour, final: final)
          dirtyDays.insert(Calendar.current.startOfDay(for: hour))
        case .day(let day):
          try await summarizeDay(day)
          dirtyDays.remove(day)
        case .meeting(let id):
          try await summarizeMeeting(id)
        }
      } catch {
        Self.logger.error("Summary failed: \(String(describing: error), privacy: .public)")
        if case .hour(let hour, _) = job { failed.insert(hour) }
      }
      if queue.isEmpty, let day = dirtyDays.first {
        queue.append(.day(day))
      }
    }
    running = false
    isWorking = false
  }

  // MARK: Generation

  private func visibleSentences(in interval: DateInterval) -> [Sentence] {
    let hidden = store.marks(overlapping: interval)
    return store.sentences(in: interval).filter { s in !hidden.contains { $0.covers(s.start) } }
  }

  private static let instructions = """
    你在为录音的主人整理他们自己一天里的对话。只根据转录内容写，不编造人名、日期或决定。\
    说话人只有三种：「我」是录音的主人，「会议对方」是会议软件里的其他人，「他人」是身边的其他人。\
    用简体中文，句子简短、具体。
    """

  private static func numbered(_ sentences: [Sentence], from start: Int = 1) -> String {
    sentences.enumerated().map { index, s in
      "[\(start + index)] \(TimeText.clock(s.start)) \(s.speaker.label)：\(s.text)"
    }.joined(separator: "\n")
  }

  /// Consecutive slices of at most `partCharacters` characters.
  private static func parts(_ sentences: [Sentence]) -> [[Sentence]] {
    var parts: [[Sentence]] = []
    var current: [Sentence] = []
    var size = 0
    for sentence in sentences {
      if size + sentence.text.count > partCharacters, !current.isEmpty {
        parts.append(current)
        current = []
        size = 0
      }
      current.append(sentence)
      size += sentence.text.count + 12
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }

  private func summarizeHour(_ hour: Date, final: Bool) async throws {
    let sentences = visibleSentences(in: DateInterval(start: hour, duration: 3_600))
    guard !sentences.isEmpty else {
      store.removeHourSummary(hourStart: hour)
      return
    }
    var notes: [String] = []
    var keys: [Int64] = []
    for part in Self.parts(sentences) {
      let session = LanguageModelSession(instructions: Self.instructions)
      let draft = try await session.respond(
        to: "下面是 \(TimeText.clock(hour)) 这一小时的转录，每句前面有编号。\n\n\(Self.numbered(part))",
        generating: HourDraft.self
      ).content
      notes.append(draft.summary)
      keys += draft.keySentences.compactMap { part.indices.contains($0 - 1) ? part[$0 - 1].id : nil }
    }
    var summary = notes.first ?? ""
    if notes.count > 1 {
      let session = LanguageModelSession(instructions: Self.instructions)
      summary = try await session.respond(
        to: "把下面几段笔记合成这一小时的总结，一到两句话：\n\n" + notes.joined(separator: "\n")
      ).content
    }
    store.saveHourSummary(HourSummary(
      hourStart: hour, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
      keySentenceIDs: Array(keys.uniqued().prefix(6)),
      generatedAt: .now, isFinal: final))
  }

  private func summarizeDay(_ day: Date) async throws {
    let interval = DateInterval(start: day, duration: 86_400)
    let hidden = store.marks(overlapping: interval)
    let summaries = store.hourSummaries(in: interval).values
      .filter { s in !hidden.contains { $0.covers(s.hourStart) } }
      .sorted { $0.hourStart < $1.hourStart }
    guard !summaries.isEmpty else { return }
    var sources: [Sentence] = []
    var lines: [String] = []
    let meetings = store.meetings(overlapping: interval)
    for summary in summaries {
      lines.append("\(TimeText.clock(summary.hourStart)) 这一小时：\(summary.summary)")
      let keys = store.sentences(ids: summary.keySentenceIDs).filter { s in !hidden.contains { $0.covers(s.start) } }
      for sentence in keys.prefix(3) {
        sources.append(sentence)
        lines.append("  [\(sources.count)] \(TimeText.clock(sentence.start)) \(sentence.speaker.label)：\(sentence.text)")
      }
    }
    let meetingLines = meetings.map { "\(TimeText.range($0.start, $0.end)) \($0.title)" }.joined(separator: "\n")
    let session = LanguageModelSession(instructions: Self.instructions)
    let draft = try await session.respond(
      to: """
        这是一天里每小时的总结和其中的原话，原话前有编号。\
        \(meetingLines.isEmpty ? "" : "当天的会议：\n\(meetingLines)\n")
        \(lines.joined(separator: "\n").prefix(3_000))
        """,
      generating: DayDraft.self
    ).content
    let cite = { (numbers: [Int]) in numbers.compactMap { sources.indices.contains($0 - 1) ? sources[$0 - 1].id : nil } }
    store.saveDaySummary(DaySummary(
      day: day,
      headline: CitedLine(text: draft.headline.text, cites: cite(draft.headline.sources)),
      details: draft.details.map { CitedLine(text: $0.text, cites: cite($0.sources)) }.filter { !$0.cites.isEmpty },
      generatedAt: .now))
  }

  private func summarizeMeeting(_ id: Int64) async throws {
    guard var meeting = store.meeting(id: id) else { return }
    let sentences = visibleSentences(in: DateInterval(start: meeting.start, end: max(meeting.end, meeting.start)))
    guard !sentences.isEmpty else { return }
    var points: [CitedLine] = []
    for part in Self.parts(sentences) {
      let session = LanguageModelSession(instructions: Self.instructions)
      let draft = try await session.respond(
        to: "下面是会议「\(meeting.title)」的转录，每句前面有编号。列出会上的结论、决定和谁答应做什么。\n\n\(Self.numbered(part))",
        generating: PointsDraft.self
      ).content
      points += draft.points.map { point in
        CitedLine(text: point.text, cites: point.sources.compactMap { part.indices.contains($0 - 1) ? part[$0 - 1].id : nil })
      }
    }
    meeting.points = Array(points.prefix(8))
    meeting.minutes = Meetings.minutes(for: meeting)
    meeting.pointsGeneratedAt = .now
    store.saveMeeting(meeting)
  }
}

@Generable
struct HourDraft {
  @Guide(description: "这一小时谈了什么，一到两句话")
  var summary: String
  @Guide(description: "最能代表这一小时内容的二到五句原话的编号", .count(0...5))
  var keySentences: [Int]
}

@Generable
struct CitedDraft {
  @Guide(description: "一句话")
  var text: String
  @Guide(description: "这句话依据的原话编号，一到三个", .count(1...3))
  var sources: [Int]
}

@Generable
struct DayDraft {
  @Guide(description: "用一句话说出今天最重要的结果")
  var headline: CitedDraft
  @Guide(description: "当天的要点，每条一句话", .count(1...6))
  var details: [CitedDraft]
}

@Generable
struct PointsDraft {
  @Guide(description: "会议要点，每条一句话", .count(1...6))
  var points: [CitedDraft]
}

extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
