import Foundation

// `wakeoncue health`: checks all-day recording over the last few days. Every minute of each day
// should be recorded, paused, private, deleted, or a gap with a reason; anything else is a hole
// the app did not explain. Also flags hours with audio but no transcript, and hours with a
// transcript but no summary.

/// Sorted, non-overlapping time ranges.
nonisolated struct TimeRanges: Equatable {
  private(set) var ranges: [DateInterval] = []

  init(_ intervals: [DateInterval] = []) {
    for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
      if let last = ranges.last, interval.start <= last.end {
        ranges[ranges.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
      } else {
        ranges.append(interval)
      }
    }
  }

  var total: TimeInterval { ranges.reduce(0) { $0 + $1.duration } }

  func clipped(to window: DateInterval) -> TimeRanges {
    TimeRanges(ranges.compactMap { range in
      let start = max(range.start, window.start), end = min(range.end, window.end)
      return end > start ? DateInterval(start: start, end: end) : nil
    })
  }

  /// The parts of `window` not covered by these ranges.
  func holes(in window: DateInterval) -> [DateInterval] {
    var holes: [DateInterval] = []
    var cursor = window.start
    for range in clipped(to: window).ranges {
      if range.start > cursor { holes.append(DateInterval(start: cursor, end: range.start)) }
      cursor = max(cursor, range.end)
    }
    if window.end > cursor { holes.append(DateInterval(start: cursor, end: window.end)) }
    return holes
  }
}

struct HealthDay: Encodable {
  struct Span: Encodable {
    let from: String
    let to: String
    let minutes: Int
    let reason: String?
  }

  let date: String
  /// Hours of the day checked so far (24, or less for today).
  let checkedHours: Double
  let microphoneHours: Double
  let meetingAppHours: Double
  let remoteHours: Double
  let pausedHours: Double
  let privateOrDeletedHours: Double
  let gaps: [Span]
  /// Time nothing accounts for: not recorded, paused, private, deleted or a gap with a reason.
  let unexplained: [Span]
  let audioMegabytes: Double
  let sentences: Int
  /// Sentences whose live text no model has replaced yet, and how many of them are longer than
  /// 2.5 seconds. Nil when no model is chosen: then not re-transcribing is expected.
  let notRefined: Int?
  let notRefinedOver2_5: Int?
  /// Hours with at least 5 minutes of audio and no sentence at all: normal when the room was
  /// quiet, worth a look when someone was talking.
  let hoursWithoutTranscript: [String]
  /// Finished hours with sentences but no final summary.
  let hoursWithoutSummary: [String]
  let hasDaySummary: Bool
}

@MainActor
func healthReport(store: Store, days: Int, now: Date = .now, modelSelected: Bool = false) -> [HealthDay] {
  let calendar = Calendar.current
  let today = calendar.startOfDay(for: now)
  let marks = store.marks()
  // Before the first recording the app was not set up yet; that time needs no reason.
  let firstRecording = store.segments(overlapping: DateInterval(start: .distantPast, end: now)).map(\.start).min() ?? now
  return (0..<days).reversed().map { offset in
    let day = calendar.date(byAdding: .day, value: -offset, to: today)!
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
    let window = DateInterval(start: min(max(day, firstRecording), now), end: min(dayEnd, now))
    let segments = store.segments(overlapping: window)
    func ranges(_ channel: AudioChannel) -> TimeRanges {
      TimeRanges(segments.filter { $0.channel == channel }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
        .clipped(to: window)
    }
    let microphone = ranges(.microphone), meeting = ranges(.meeting), remote = ranges(.remote)
    let paused = TimeRanges(marks.filter { $0.kind == .paused }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
      .clipped(to: window)
    let hidden = TimeRanges(marks.filter { $0.kind != .paused }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
      .clipped(to: window)
    let gaps = store.gaps(overlapping: window)
    let gapRanges = TimeRanges(gaps.map { DateInterval(start: $0.start, end: max($0.start, $0.end ?? now)) }).clipped(to: window)
    let explained = TimeRanges(microphone.ranges + remote.ranges + paused.ranges + hidden.ranges + gapRanges.ranges)
    let unexplained = explained.holes(in: window).filter { $0.duration >= 120 }

    let sentences = store.sentences(in: window)
    let refinement = modelSelected ? store.unrefinedCounts(in: window) : nil
    let summaries = store.hourSummaries(in: DateInterval(start: day, end: dayEnd))
    var withoutTranscript: [String] = []
    var withoutSummary: [String] = []
    var hour = day
    while hour < window.end {
      let hourWindow = DateInterval(start: hour, duration: 3_600)
      let audio = TimeRanges(microphone.ranges + meeting.ranges + remote.ranges).clipped(to: hourWindow).total
        - hidden.clipped(to: hourWindow).total
      let spoken = sentences.contains { sentence in
        hourWindow.contains(sentence.start) && !hidden.ranges.contains { $0.contains(sentence.start) }
      }
      if audio >= 300 && !spoken && hourWindow.end < now { withoutTranscript.append(TimeText.clock(hour)) }
      // The current hour and the one just finished may still be summarizing.
      if spoken && hourWindow.end.addingTimeInterval(1_800) < now && summaries[hour]?.isFinal != true {
        withoutSummary.append(TimeText.clock(hour))
      }
      hour = hourWindow.end
    }

    let bytes = segments.filter { $0.start >= day && $0.start < dayEnd }.reduce(Int64(0)) { total, segment in
      let size = (try? Store.audioDirectory.appending(path: segment.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return total + Int64(size ?? 0)
    }
    func span(_ interval: DateInterval, _ reason: String? = nil) -> HealthDay.Span {
      HealthDay.Span(
        from: TimeText.clock(interval.start), to: TimeText.clock(interval.end),
        minutes: Int((interval.duration / 60).rounded()), reason: reason)
    }
    func hours(_ ranges: TimeRanges) -> Double { (ranges.total / 360).rounded() / 10 }
    return HealthDay(
      date: TimeText.dayFolder(day),
      checkedHours: (window.duration / 360).rounded() / 10,
      microphoneHours: hours(microphone), meetingAppHours: hours(meeting), remoteHours: hours(remote),
      pausedHours: hours(paused), privateOrDeletedHours: hours(hidden),
      gaps: gaps.map { gap in
        span(DateInterval(start: max(gap.start, window.start), end: min(max(gap.start, gap.end ?? now), window.end)), gap.reason)
      },
      unexplained: unexplained.map { span($0) },
      audioMegabytes: (Double(bytes) / 100_000).rounded() / 10,
      sentences: sentences.count,
      notRefined: refinement?.total,
      notRefinedOver2_5: refinement?.overTwoSeconds,
      hoursWithoutTranscript: withoutTranscript,
      hoursWithoutSummary: withoutSummary,
      hasDaySummary: store.daySummary(for: day) != nil)
  }
}

func printHealth(_ days: [HealthDay], remote: [String: (total: Int, waiting: Int, latest: Date?)]) {
  var problems = 0
  for day in days {
    print("\(day.date)（检查了 \(day.checkedHours) 小时）")
    print("  录音：麦克风 \(day.microphoneHours) 小时，会议 App \(day.meetingAppHours) 小时，手表和 iPhone \(day.remoteHours) 小时；音频 \(day.audioMegabytes) MB")
    if day.pausedHours > 0 || day.privateOrDeletedHours > 0 {
      print("  暂停 \(day.pausedHours) 小时，私人或已删除 \(day.privateOrDeletedHours) 小时")
    }
    for gap in day.gaps { print("  录不了 \(gap.from)–\(gap.to)（\(gap.minutes) 分钟）：\(gap.reason ?? "")") }
    for hole in day.unexplained {
      problems += 1
      print("  ! 没有录音也没有原因 \(hole.from)–\(hole.to)（\(hole.minutes) 分钟）")
    }
    if !day.hoursWithoutTranscript.isEmpty {
      print("  有音频但没有转录（没人说话时正常）：\(day.hoursWithoutTranscript.joined(separator: "、"))")
    }
    if !day.hoursWithoutSummary.isEmpty {
      problems += 1
      print("  ! 有转录但没有总结：\(day.hoursWithoutSummary.joined(separator: "、"))")
    }
    print("  转录 \(day.sentences) 句，当天总结：\(day.hasDaySummary ? "有" : "没有")")
    if let notRefined = day.notRefined, let over = day.notRefinedOver2_5 {
      print("  还没重转：\(notRefined) 句（超过 2.5 秒的 \(over) 句）")
    }
  }
  if !remote.isEmpty {
    print("\n手表和 iPhone 回传")
    for (device, counts) in remote.sorted(by: { $0.key < $1.key }) {
      let latest = counts.latest.map { " 最近一段 \(TimeText.dayFolder($0)) \(TimeText.clock($0))" } ?? ""
      print("  设备 \(device)：\(counts.total) 段，等待合并 \(counts.waiting) 段\(latest)")
    }
  }
  print(problems == 0 ? "\n没有发现问题。" : "\n发现 \(problems) 处需要看一下（标 ! 的行）。")
}
