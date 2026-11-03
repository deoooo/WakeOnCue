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
    /// Share of the speech that belongs to a meeting, 0...1.
    let meetingShare: Double
    let meetings: [Meeting]
    let summary: HourSummary?
    let sentences: [Sentence]
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
  let meetings: [Meeting]
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
    let meetings = store.meetings(overlapping: interval).filter { !hidden($0.start) }

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
      let inMeetings = meetings.filter { $0.start < hour.end && $0.end > hour.start }
      let meetingSpeech = inHour.filter { sentence in inMeetings.contains { $0.start <= sentence.start && sentence.start < $0.end } }
        .reduce(0) { $0 + max(1, $1.end.timeIntervalSince($1.start)) } / 60
      return Hour(
        interval: hour, state: state, speechMinutes: speech,
        meetingShare: speech > 0 ? min(1, meetingSpeech / speech) : 0,
        meetings: inMeetings, summary: summaries[hour.start], sentences: inHour)
    }
    let shown = hours.filter { $0.state != .none }
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
    let recorded = segments.filter { $0.channel == .microphone }.reduce(0) {
      $0 + min($1.end, interval.end).timeIntervalSince(max($1.start, interval.start))
    }
    return DayData(
      day: start, hours: hours, rows: rows, meetings: meetings, summary: summary,
      visibleDetails: summary?.details.filter(visible) ?? [],
      headlineCites: summary?.headline.cites.filter { byID[$0] != nil } ?? [],
      recordedSeconds: recorded, segments: segments, marks: marks, sentencesByID: byID)
  }

  private static func gapText(_ gap: CaptureGap, hour: DateInterval) -> String {
    if gap.start > hour.start {
      return "\(TimeText.clock(gap.start)) 起\(gap.reason)，这段没有录到声音。"
    }
    return "\(gap.reason)，这一小时没有录到声音。"
  }

  func sentence(_ id: Int64) -> Sentence? { sentencesByID[id] }

  func hour(containing date: Date) -> Hour? { hours.first { $0.interval.contains(date) } }

  func sentences(in meeting: Meeting) -> [Sentence] {
    hours.flatMap(\.sentences).filter { $0.start >= meeting.start && $0.start < meeting.end }
  }
}
