import Foundation
import Observation
import OSLog

/// Hour, day and meeting summaries. Each finished hour gets its summary and key sentences; the
/// running hour gets a provisional one every 15 minutes; the day summary follows the hours.
/// Private and deleted ranges never reach the engine. The engine is Apple Intelligence when
/// this Mac has it, otherwise the user's gateway (or always the gateway, if they chose so).
@Observable
final class Summaries {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Summaries")
  /// A failed hour is tried again after this long, e.g. once the network is back.
  private static let retryAfter: TimeInterval = 10 * 60

  /// Why summaries cannot be generated now, or nil when an engine is ready.
  private(set) var unavailableReason: String?
  /// The engine summaries will use, e.g. "本机 Apple 智能" or "网关 gpt-4o-mini".
  private(set) var engineName: String?
  /// Where transcripts are sent, or nil when they stay on this Mac.
  private(set) var destination: String?
  private(set) var isWorking = false
  private(set) var lastError: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var engine: (any SummaryEngine)?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var queue: [Job] = []
  @ObservationIgnored private var running = false
  @ObservationIgnored private var failed: [Date: Date] = [:]
  @ObservationIgnored private var provisionalAt: [Date: (time: Date, count: Int)] = [:]
  @ObservationIgnored private var dirtyDays: Set<Date> = []

  private enum Job: Equatable {
    case hour(Date, final: Bool)
    case day(Date)
    case meeting(Int64)
  }

  init(store: Store, preferences: Preferences) {
    self.store = store
    self.preferences = preferences
    refreshEngine()
  }

  func start() {
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        self?.refreshEngine()
        self?.scan()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  /// The gateway configuration as it stands, with the key from the keychain.
  var gatewayConfig: GatewayConfig {
    preferences.gateway
  }

  /// True once the gateway is filled in and the user agreed to send transcripts to its host.
  var gatewayReady: Bool {
    let config = gatewayConfig
    return config.isComplete && preferences.gatewayConsentHost == config.host
  }

  /// Picks the engine again; call after settings change.
  func refreshEngine() {
    let apple = AppleIntelligenceEngine.unavailableReason
    let next: (any SummaryEngine)?
    var reason: String?
    switch preferences.summaryEngine {
    case .gateway:
      next = gatewayReady ? GatewayEngine(config: gatewayConfig) : nil
      if next == nil { reason = "网关还没有设置好" }
    case .automatic:
      if apple == nil {
        next = AppleIntelligenceEngine()
      } else if gatewayReady {
        next = GatewayEngine(config: gatewayConfig)
      } else {
        next = nil
        reason = apple
      }
    }
    let changed = next?.name != engine?.name || next?.destination != engine?.destination
      || (next as? GatewayEngine)?.config != (engine as? GatewayEngine)?.config
    engine = next
    engineName = next?.name
    destination = next?.destination
    unavailableReason = reason
    if changed, next != nil {
      failed = [:]
      scan()
    }
  }

  // MARK: Placeholders

  func dayPlaceholder(for data: DayData) -> String {
    if let reason = unavailableReason { return "\(reason)，没有生成当天总结。可以在设置 › AI 服务里配置网关。" }
    return data.rows.contains { $0.state == .speech } ? "第一个小时结束后会生成当天总结。" : "这一天还没有人说话。"
  }

  func hourPlaceholder(for hour: DayData.Hour) -> String {
    if let reason = unavailableReason { return "\(reason)，这一小时没有总结。展开原文可查看转录。" }
    if failed[hour.interval.start] != nil {
      return "这一小时没能生成总结\(lastError.map { "（\($0)）" } ?? "")，稍后会重试。展开原文可查看转录。"
    }
    return hour.isCurrent ? "正在听，稍后给出这一小时的临时总结。" : "正在生成这一小时的总结…"
  }

  /// "本机 Apple 智能生成 · 16:30 更新", plus where the transcript went when it left this Mac.
  static func credit(engine: String?, at date: Date) -> String {
    "\(engine ?? "本机 Apple 智能")生成 · \(TimeText.clock(date)) 更新"
  }

  // MARK: Scheduling

  /// Something changed in this range (marked private, deleted, restored): redo what it touches.
  func invalidate(_ interval: DateInterval) {
    let calendar = Calendar.current
    var hour = calendar.hourStart(interval.start)
    while hour < interval.end {
      failed[hour] = nil
      enqueue(.hour(hour, final: !DateInterval(start: hour, duration: 3_600).contains(.now)))
      hour = hour.addingTimeInterval(3_600)
    }
    enqueue(.day(calendar.startOfDay(for: interval.start)))
  }

  func regenerateMeeting(_ id: Int64) {
    enqueue(.meeting(id))
  }

  /// Regenerates one hour now, e.g. from the hour's menu.
  func regenerate(hour: Date) {
    failed[hour] = nil
    enqueue(.hour(hour, final: !DateInterval(start: hour, duration: 3_600).contains(.now)))
  }

  /// Finished hours without a final summary, and the running hour every 15 minutes.
  private func scan() {
    guard engine != nil else { return }
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let window = DateInterval(start: today.addingTimeInterval(-86_400), end: now)
    let summaries = store.hourSummaries(in: window)
    let hidden = store.marks(overlapping: window)
    let sentences = store.sentences(in: window).filter { s in !hidden.contains { $0.covers(s.start) } }
    let byHour = Dictionary(grouping: sentences) { calendar.hourStart($0.start) }
    for (hour, list) in byHour.sorted(by: { $0.key < $1.key }) {
      if let at = failed[hour], now.timeIntervalSince(at) < Self.retryAfter { continue }
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
      guard let engine else { continue }
      do {
        switch job {
        case .hour(let hour, let final):
          try await summarizeHour(hour, final: final, engine: engine)
          failed[hour] = nil
          dirtyDays.insert(Calendar.current.startOfDay(for: hour))
        case .day(let day):
          try await summarizeDay(day, engine: engine)
          dirtyDays.remove(day)
        case .meeting(let id):
          try await summarizeMeeting(id, engine: engine)
        }
        lastError = nil
      } catch {
        Self.logger.error("Summary failed: \(String(describing: error), privacy: .public)")
        lastError = error.localizedDescription
        if case .hour(let hour, _) = job { failed[hour] = .now }
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

  private static func numbered(_ sentences: [Sentence]) -> String {
    sentences.enumerated().map { index, s in
      "[\(index + 1)] \(TimeText.clock(s.start)) \(s.speakerLabel)：\(s.text)"
    }.joined(separator: "\n")
  }

  /// Consecutive slices of at most `limit` characters.
  private static func parts(_ sentences: [Sentence], limit: Int) -> [[Sentence]] {
    var parts: [[Sentence]] = []
    var current: [Sentence] = []
    var size = 0
    for sentence in sentences {
      if size + sentence.text.count > limit, !current.isEmpty {
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

  private static func ids(_ numbers: [Int], in part: [Sentence]) -> [Int64] {
    numbers.compactMap { part.indices.contains($0 - 1) ? part[$0 - 1].id : nil }
  }

  private func summarizeHour(_ hour: Date, final: Bool, engine: any SummaryEngine) async throws {
    let sentences = visibleSentences(in: DateInterval(start: hour, duration: 3_600))
    guard !sentences.isEmpty else {
      store.removeHourSummary(hourStart: hour)
      return
    }
    var notes: [String] = []
    var keys: [Int64] = []
    for part in Self.parts(sentences, limit: engine.partCharacters) {
      let result = try await engine.hour(
        "下面是 \(TimeText.clock(hour)) 这一小时的转录，每句前面有编号。总结这一小时谈了什么，并挑出最能代表内容的二到五句原话。\n\n\(Self.numbered(part))")
      notes.append(result.summary)
      keys += Self.ids(result.keySentences, in: part)
    }
    var summary = notes.first ?? ""
    if notes.count > 1 {
      summary = try await engine.text("把下面几段笔记合成这一小时的总结，一到两句话，只输出总结：\n\n" + notes.joined(separator: "\n"))
    }
    store.saveHourSummary(HourSummary(
      hourStart: hour, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
      keySentenceIDs: Array(keys.uniqued().prefix(6)),
      generatedAt: .now, isFinal: final, engine: engine.name))
  }

  private func summarizeDay(_ day: Date, engine: any SummaryEngine) async throws {
    let interval = DateInterval(start: day, duration: 86_400)
    let hidden = store.marks(overlapping: interval)
    let summaries = store.hourSummaries(in: interval).values
      .filter { s in !hidden.contains { $0.covers(s.hourStart) } }
      .sorted { $0.hourStart < $1.hourStart }
    guard !summaries.isEmpty else { return }
    var sources: [Sentence] = []
    var lines: [String] = []
    let meetings = store.meetings(overlapping: interval).filter { m in !hidden.contains { $0.covers(m.start) } }
    for summary in summaries {
      lines.append("\(TimeText.clock(summary.hourStart)) 这一小时：\(summary.summary)")
      let keys = store.sentences(ids: summary.keySentenceIDs).filter { s in !hidden.contains { $0.covers(s.start) } }
      for sentence in keys.prefix(3) {
        sources.append(sentence)
        lines.append("  [\(sources.count)] \(TimeText.clock(sentence.start)) \(sentence.speakerLabel)：\(sentence.text)")
      }
    }
    let meetingLines = meetings.map { "\(TimeText.range($0.start, $0.end)) \($0.title)" }.joined(separator: "\n")
    let material = lines.joined(separator: "\n").prefix(engine.partCharacters * 2)
    let result = try await engine.day("""
      这是一天里每小时的总结和其中的原话，原话前有编号。写出今天最重要的一句话，以及当天的要点，每条都注明依据的原话编号。
      \(meetingLines.isEmpty ? "" : "当天的会议：\n\(meetingLines)\n")
      \(material)
      """)
    let cite = { (numbers: [Int]) in numbers.compactMap { sources.indices.contains($0 - 1) ? sources[$0 - 1].id : nil } }
    store.saveDaySummary(DaySummary(
      day: day,
      headline: CitedLine(text: result.headline.text, cites: cite(result.headline.sources)),
      details: result.details.map { CitedLine(text: $0.text, cites: cite($0.sources)) }.filter { !$0.cites.isEmpty },
      generatedAt: .now, engine: engine.name))
  }

  private func summarizeMeeting(_ id: Int64, engine: any SummaryEngine) async throws {
    guard var meeting = store.meeting(id: id) else { return }
    let sentences = visibleSentences(in: DateInterval(start: meeting.start, end: max(meeting.end, meeting.start)))
    guard !sentences.isEmpty else { return }
    var points: [CitedLine] = []
    for part in Self.parts(sentences, limit: engine.partCharacters) {
      let results = try await engine.points(
        "下面是会议「\(meeting.title)」的转录，每句前面有编号。列出会议要点：先写结论、决定和谁答应做什么；没有明确决定时，就写谈了哪些事、各自的进展或问题。每条注明依据的原话编号，至少列出一条。\n\n\(Self.numbered(part))")
      points += results.map { CitedLine(text: $0.text, cites: Self.ids($0.sources, in: part)) }
    }
    meeting.points = Array(points.prefix(8))
    meeting.minutes = Meetings.minutes(for: meeting)
    meeting.pointsGeneratedAt = .now
    meeting.pointsEngine = engine.name
    store.saveMeeting(meeting)
  }
}

extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
