import Foundation

/// Everything the day page shows, read from the store in one pass. Private and deleted ranges
/// are removed here, so nothing downstream can show or play them.
struct DayData {
  enum HourState: Equatable {
    case speech
    case quiet
    case none
    case privateHour
    case deleted
    case gap(String)
  }

  struct Hour: Identifiable {
    let interval: DateInterval
    let state: HourState
    let speechMinutes: Double
    let summary: HourSummary?
    let sentences: [Sentence]
    /// Watch and iPhone marks that start in this hour, outside private and deleted time.
    var deviceMarks: [DeviceMark] = []
    var id: Date { interval.start }
    var hour: Int { Calendar.current.component(.hour, from: interval.start) }
    var clock: String { String(format: "%02d:00", hour) }

    var keySentences: [Sentence] {
      guard let ids = summary?.keySentenceIDs, !ids.isEmpty else { return [] }
      return sentences.filter { ids.contains($0.id) }
    }

    var isCurrent: Bool { interval.contains(.now) }
  }

  let day: Date
  let hours: [Hour]
  /// Hours that get a row: anything recorded, marked or missed, from the first to the last.
  let rows: [Hour]
  let summary: DaySummary?
  let visibleDetails: [CitedLine]
  let headlineCites: [Int64]
  let recordedSeconds: TimeInterval
  let segments: [AudioSegment]
  let marks: [TimeMark]
  let sentencesByID: [Int64: Sentence]

  static func load(day: Date, store: Store) -> DayData {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: day)
    let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    let marks = store.marks(overlapping: interval)
    let gaps = store.gaps(overlapping: interval)
    let segments = store.segments(overlapping: interval)
    let hidden = { (date: Date) in marks.contains { $0.covers(date) } }
    let sentences = store.sentences(in: interval).filter { !hidden($0.start) }
    let summaries = store.hourSummaries(in: interval)
    let deviceMarks = store.deviceMarks(overlapping: interval).filter { !hidden($0.start) }

    let hours = calendar.hours(of: day).map { hour -> Hour in
      let inHour = sentences.filter { hour.contains($0.start) }
      let speech = inHour.reduce(0) { $0 + max(1, $1.end.timeIntervalSince($1.start)) } / 60
      let recorded = segments.contains { $0.start < hour.end && $0.end > hour.start }
      let fullyMarked = { (kind: TimeMark.Kind) in
        marks.contains { $0.kind == kind && $0.start <= hour.start && $0.end >= hour.end }
      }
      let gap = gaps.first { $0.start < hour.end && ($0.end ?? .now) > hour.start }
      let state: HourState =
        if fullyMarked(.deleted) { .deleted }
        else if fullyMarked(.privateRange) { .privateHour }
        else if !inHour.isEmpty { .speech }
        else if let gap, !recorded { .gap(Self.gapText(gap, hour: hour)) }
        else if recorded { .quiet }
        else { .none }
      return Hour(
        interval: hour, state: state, speechMinutes: speech, summary: summaries[hour.start], sentences: inHour,
        deviceMarks: state == .privateHour || state == .deleted ? [] : deviceMarks.filter { $0.start >= hour.start && $0.start < hour.end })
    }
    let shown = hours.filter { $0.state != .none || !$0.deviceMarks.isEmpty }
    let rows: [Hour]
    if let first = shown.first, let last = shown.last {
      rows = hours.filter { $0.interval.start >= first.interval.start && $0.interval.start <= last.interval.start }
    } else {
      rows = []
    }

    let byID = Dictionary(sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // A summary line is dropped as soon as any of its sources is hidden or gone.
    let visible = { (line: CitedLine) in !line.cites.isEmpty && line.cites.allSatisfy { byID[$0] != nil } }
    let summary = store.daySummary(for: start)
    return DayData(
      day: start, hours: hours, rows: rows, summary: summary,
      visibleDetails: summary?.details.filter(visible) ?? [],
      headlineCites: summary?.headline.cites.filter { byID[$0] != nil } ?? [],
      recordedSeconds: recordedDuration(segments: segments, in: interval),
      segments: segments, marks: marks, sentencesByID: byID)
  }

  /// Total time covered by any audio, merging overlapping Mac and forwarded segments so a Watch
  /// recording that fills a Mac gap is not counted twice.
  static func recordedDuration(segments: [AudioSegment], in interval: DateInterval) -> TimeInterval {
    // A segment can end before it starts, e.g. one just opened whose start, counted in samples,
    // is a moment ahead of the wall clock. `DateInterval` traps on that, so skip such ranges.
    let ranges = segments.compactMap { segment -> DateInterval? in
      let start = max(segment.start, interval.start)
      let end = min(segment.end, interval.end)
      return end > start ? DateInterval(start: start, end: end) : nil
    }
      .sorted { $0.start < $1.start }
    var total: TimeInterval = 0
    var current: DateInterval?
    for range in ranges {
      guard let open = current else {
        current = range
        continue
      }
      if range.start <= open.end {
        current = DateInterval(start: open.start, end: max(open.end, range.end))
      } else {
        total += open.duration
        current = range
      }
    }
    if let current { total += current.duration }
    return total
  }

  private static func gapText(_ gap: CaptureGap, hour: DateInterval) -> String {
    if gap.start > hour.start {
      return "\(TimeText.clock(gap.start)) 起\(gap.reason)，这段没有录到声音。"
    }
    return "\(gap.reason)，这一小时没有录到声音。"
  }

  func sentence(_ id: Int64) -> Sentence? { sentencesByID[id] }

  func hour(containing date: Date) -> Hour? { hours.first { $0.interval.contains(date) } }
}
