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
  /// Whether "我" on the microphone is the user's voice; see `SummaryMaterial.forSummary`.
  @ObservationIgnored var knowsMyVoice: () -> Bool = { true }
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private(set) var engine: (any SummaryEngine)?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var queue: [Job] = []
  @ObservationIgnored private var running = false
  @ObservationIgnored private var failed: [Date: Date] = [:]
  @ObservationIgnored private var provisionalAt: [Date: (time: Date, count: Int)] = [:]
  @ObservationIgnored private var dirtyDays: Set<Date> = []
  /// True while a re-transcription is still changing the day: hours are summarized as they
  /// finish, the day once at the end (`releaseDays`), not after every hour.
  @ObservationIgnored var holdsDays: () -> Bool = { false }

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
    if hour.summary?.isFinal == true || (!hour.isCurrent && SummaryMaterial.isThin(hour.sentences)) {
      return "只有零星几句，没有可总结的内容。展开原文可查看转录。"
    }
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

  /// Only the day summary again, e.g. after Watch marks arrived: the hours do not use them.
  func redoDay(containing date: Date) {
    enqueue(.day(Calendar.current.startOfDay(for: date)))
  }

  /// Writes the day summaries held back during a re-transcription.
  func releaseDays() {
    guard !holdsDays() else { return }
    for day in dirtyDays.sorted() { enqueue(.day(day)) }
  }

  func regenerateMeeting(_ id: Int64) {
    enqueue(.meeting(id))
  }

  /// True when `engine` wrote a summary but another engine is chosen now, e.g. after switching
  /// from Apple Intelligence to the gateway. Old summaries stay until regenerated.
  func isOutdated(engine: String?) -> Bool {
    guard let engineName else { return false }
    return (engine ?? AppleIntelligenceEngine().name) != engineName
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
    guard !queue.contains(job), !AppModel.viewOnly else { return }
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
      if queue.isEmpty, !holdsDays(), let day = dirtyDays.first {
        queue.append(.day(day))
      }
    }
    running = false
    isWorking = false
  }

  // MARK: Generation

  private func visibleSentences(in interval: DateInterval) -> [Sentence] {
    let hidden = store.marks(overlapping: interval)
    let visible = store.sentences(in: interval).filter { s in !hidden.contains { $0.covers(s.start) } }
    return SummaryMaterial.forSummary(visible, knowsMyVoice: knowsMyVoice())
  }

  /// Drops a leading "这一小时（里），" and a closing "没有形成明确结论", also from older summaries.
  nonisolated static func tidy(_ summary: String) -> String {
    SummaryMaterial.tidy(summary)
  }

  private static func ids(_ numbers: [Int], in part: [Sentence]) -> [Int64] {
    numbers.compactMap { part.indices.contains($0 - 1) ? part[$0 - 1].id : nil }
  }

  private func summarizeHour(_ hour: Date, final: Bool, engine: any SummaryEngine) async throws {
    let sentences = visibleSentences(in: DateInterval(start: hour, duration: 3_600))
    // A lone "嗯" or half a sentence: an empty summary, so the hour shows that little was said
    // instead of "只有一句应答，没有形成结论", and is not asked for again.
    guard !SummaryMaterial.isThin(sentences) else {
      store.saveHourSummary(HourSummary(hourStart: hour, summary: "", keySentenceIDs: [], generatedAt: .now, isFinal: final, engine: engine.name))
      return
    }
    var notes: [String] = []
    var keys: [Int64] = []
    for part in SummaryMaterial.parts(SummaryMaterial.meaningful(sentences), limit: engine.partCharacters) {
      let results = try await SummaryMaterial.halving(part, engine: engine) { try await engine.hour(SummaryMaterial.hourPrompt(hour, part: $0)) }
      for (result, piece) in results {
        notes.append(result.summary)
        keys += Self.ids(result.keySentences, in: piece)
      }
    }
    var summary = notes.first ?? ""
    if notes.count > 1 {
      summary = try await engine.text(SummaryMaterial.mergePrompt(notes))
    }
    store.saveHourSummary(HourSummary(
      hourStart: hour, summary: Self.tidy(summary),
      keySentenceIDs: Array(keys.uniqued().prefix(6)),
      generatedAt: .now, isFinal: final, engine: engine.name))
  }

  private func summarizeDay(_ day: Date, engine: any SummaryEngine) async throws {
    let interval = DateInterval(start: day, duration: 86_400)
    let hidden = store.marks(overlapping: interval)
    let summaries = store.hourSummaries(in: interval).values
      .filter { s in !s.summary.isEmpty && !hidden.contains { $0.covers(s.hourStart) } }
      .sorted { $0.hourStart < $1.hourStart }
    guard !summaries.isEmpty else { return }
    let meetings = store.meetings(overlapping: interval).filter { m in !hidden.contains { $0.covers(m.start) } }
    let hours = summaries.map { summary in
      SummaryMaterial.DayHour(
        start: summary.hourStart, summary: summary.summary,
        keys: SummaryMaterial.forSummary(
          store.sentences(ids: summary.keySentenceIDs).filter { s in !hidden.contains { $0.covers(s.start) } },
          knowsMyVoice: knowsMyVoice()))
    }
    // What the user marked on the Watch or iPhone, important and to-do first, with what was said.
    var sources: [Sentence] = []
    let marks = store.deviceMarks(overlapping: interval).filter { m in !hidden.contains { $0.covers(m.start) } }
      .sorted { ($0.isPriority ? 0 : 1, $0.start) < ($1.isPriority ? 0 : 1, $1.start) }
    var markLines: [String] = []
    for mark in marks.prefix(8) {
      let range = mark.end.map { TimeText.range(mark.start, $0) } ?? TimeText.clock(mark.start)
      markLines.append("\(range) 标为「\(mark.label)」")
      // A point mark looks at the minute before it, like "记下刚才".
      let span = mark.interval.duration >= 1 ? mark.interval : DateInterval(start: mark.start.addingTimeInterval(-60), end: mark.start.addingTimeInterval(15))
      for sentence in visibleSentences(in: span).prefix(mark.isPriority ? 3 : 1) {
        sources.append(sentence)
        markLines.append("  [\(sources.count)] \(TimeText.clock(sentence.start)) \(sentence.speakerLabel)：\(sentence.text)")
      }
    }
    // Marked stretches go first and are kept whole; the hours share what is left.
    let marked = markLines.isEmpty ? "" : "主人在手表或 iPhone 上标记的时段（标为「重要」「待办」的必须写进要点，待办写成要做的事）：\n" + markLines.joined(separator: "\n") + "\n\n"
    let (hourText, hourSources) = SummaryMaterial.dayMaterial(
      hours, budget: max(engine.partCharacters * 2 - marked.count, engine.partCharacters / 2), firstNumber: sources.count + 1)
    sources += hourSources
    let result = try await engine.day(SummaryMaterial.dayPrompt(
      material: marked + hourText, meetings: meetings.map { "\(TimeText.range($0.start, $0.end)) \($0.title)" }))
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
    for part in SummaryMaterial.parts(SummaryMaterial.meaningful(sentences), limit: engine.partCharacters) {
      let results = try await SummaryMaterial.halving(part, engine: engine) {
        try await engine.points(
          "下面是会议「\(meeting.title)」的转录，每句前面有编号。列出会议要点：先写结论、决定和谁答应做什么；没有明确决定时，就写谈了哪些事、各自的进展或问题。每条注明依据的原话编号，至少列出一条。\n\n\(SummaryMaterial.numbered($0))")
      }
      for (result, piece) in results {
        points += result.map { CitedLine(text: $0.text, cites: Self.ids($0.sources, in: piece)) }
      }
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
