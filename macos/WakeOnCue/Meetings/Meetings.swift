import EventKit
import Foundation
import Observation
import OSLog

/// Finds the day's meetings: calendar events with speech in them, calls in a meeting app without
/// a calendar event, and conversations the user marked. Calendar times are moved to where the
/// talking actually started and stopped. Asks for key points a few minutes after a meeting ends.
@Observable
final class Meetings {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Meetings")
  /// Talking this close to the calendar start still belongs to the meeting.
  private static let earlyStart: TimeInterval = 10 * 60
  /// How far past the calendar end the meeting may run, and the pause that ends it.
  private static let overrun: TimeInterval = 30 * 60
  private static let pause: TimeInterval = 3 * 60
  /// Key points are generated once a meeting has been over for this long.
  private static let settle: TimeInterval = 3 * 60

  private(set) var calendarAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let summaries: Summaries
  @ObservationIgnored private let eventStore = EKEventStore()
  @ObservationIgnored private var ticker: Task<Void, Never>?

  init(store: Store, summaries: Summaries) {
    self.store = store
    self.summaries = summaries
  }

  func start() {
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        self?.scan(day: .now)
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  func requestCalendarAccess() async {
    _ = try? await eventStore.requestFullAccessToEvents()
    calendarAccess = EKEventStore.authorizationStatus(for: .event)
    scan(day: .now)
  }

  func scan(day: Date) {
    calendarAccess = EKEventStore.authorizationStatus(for: .event)
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: day)
    let interval = DateInterval(start: start, duration: 86_400)
    let hidden = store.marks(overlapping: interval)
    let sentences = store.sentences(in: interval).filter { s in !hidden.contains { $0.covers(s.start) } }
    guard !sentences.isEmpty else { return }
    if calendarAccess == .fullAccess { matchCalendar(interval: interval, sentences: sentences) }
    detectCalls(interval: interval, sentences: sentences)
    for meeting in store.meetings(overlapping: interval)
    where meeting.pointsGeneratedAt == nil && meeting.end.addingTimeInterval(Self.settle) < .now {
      summaries.regenerateMeeting(meeting.id)
    }
  }

  private func matchCalendar(interval: DateInterval, sentences: [Sentence]) {
    let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
    for event in eventStore.events(matching: predicate) where !event.isAllDay && event.startDate <= .now {
      guard let range = Self.spokenRange(start: event.startDate, end: event.endDate, sentences: sentences) else { continue }
      let existing = store.meeting(calendarEventID: event.eventIdentifier, day: interval.start)
      var meeting = existing ?? Meeting(
        id: 0, title: event.title ?? "会议", start: range.start, end: range.end, origin: .calendar,
        calendarEventID: event.eventIdentifier, calendarStart: event.startDate, calendarEnd: event.endDate,
        app: nil, attendees: [], points: [], minutes: nil, pointsGeneratedAt: nil, userAdjusted: false)
      meeting.title = event.title ?? meeting.title
      meeting.calendarStart = event.startDate
      meeting.calendarEnd = event.endDate
      meeting.attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }.map { participant in
        let email = participant.url.absoluteString.hasPrefix("mailto:")
          ? String(participant.url.absoluteString.dropFirst(7)) : nil
        return Attendee(name: participant.name ?? email ?? "参会人", email: email)
      }
      if !meeting.userAdjusted {
        // Points made for a shorter meeting are out of date once it grows.
        if range.end > meeting.end.addingTimeInterval(60) { meeting.pointsGeneratedAt = nil }
        meeting.start = range.start
        meeting.end = range.end
      }
      meeting.app = Self.app(in: meeting, sentences: sentences)
      store.saveMeeting(meeting)
    }
  }

  /// A stretch of talk in a meeting app with no calendar event becomes a meeting of its own.
  private func detectCalls(interval: DateInterval, sentences: [Sentence]) {
    let known = store.meetings(overlapping: interval)
    var clusters: [[Sentence]] = []
    for sentence in sentences where sentence.channel == .meeting {
      if let last = clusters.last?.last, sentence.start.timeIntervalSince(last.end) < 5 * 60 {
        clusters[clusters.count - 1].append(sentence)
      } else {
        clusters.append([sentence])
      }
    }
    for cluster in clusters {
      guard let first = cluster.first, let last = cluster.last,
        last.end.timeIntervalSince(first.start) >= 3 * 60,
        last.end.addingTimeInterval(5 * 60) < .now
      else { continue }
      // Include the user's side around the call.
      let mine = sentences.filter { $0.start >= first.start.addingTimeInterval(-60) && $0.start <= last.end.addingTimeInterval(60) }
      let start = mine.first?.start ?? first.start
      let end = max(last.end, mine.last?.end ?? last.end)
      guard !known.contains(where: { $0.start < end && $0.end > start }) else { continue }
      store.saveMeeting(Meeting(
        id: 0, title: "\(first.source) 通话", start: start, end: end, origin: .meetingAudio, calendarEventID: nil,
        calendarStart: nil, calendarEnd: nil, app: first.source, attendees: [], points: [], minutes: nil,
        pointsGeneratedAt: nil, userAdjusted: false))
    }
  }

  /// When the talking around a calendar event actually started and stopped.
  static func spokenRange(start: Date, end: Date, sentences: [Sentence]) -> DateInterval? {
    let inside = sentences.filter { $0.start >= start.addingTimeInterval(-earlyStart) && $0.start < end }
    guard let first = inside.first, var last = inside.last else { return nil }
    for sentence in sentences where sentence.start > last.start {
      guard sentence.start <= end.addingTimeInterval(overrun), sentence.start.timeIntervalSince(last.end) < pause else { break }
      last = sentence
    }
    return DateInterval(start: first.start, end: max(last.end, first.start.addingTimeInterval(60)))
  }

  private static func app(in meeting: Meeting, sentences: [Sentence]) -> String? {
    sentences.first { $0.channel == .meeting && $0.start >= meeting.start && $0.start < meeting.end }?.source
  }

  // MARK: User actions

  /// "标成一场会议…": the talk in this hour becomes a meeting the user can rename and adjust.
  func markMeeting(in hour: DateInterval) -> Int64? {
    let hidden = store.marks(overlapping: hour)
    let sentences = store.sentences(in: hour).filter { s in !hidden.contains { $0.covers(s.start) } }
    guard let first = sentences.first, let last = sentences.last else { return nil }
    let id = store.saveMeeting(Meeting(
      id: 0, title: "\(TimeText.clock(first.start)) 的对话", start: first.start, end: last.end, origin: .manual,
      calendarEventID: nil, calendarStart: nil, calendarEnd: nil,
      app: sentences.first { $0.channel == .meeting }?.source, attendees: [], points: [], minutes: nil,
      pointsGeneratedAt: nil, userAdjusted: true))
    summaries.regenerateMeeting(id)
    return id
  }

  func adjust(_ id: Int64, title: String, start: Date, end: Date) {
    guard var meeting = store.meeting(id: id) else { return }
    let moved = meeting.start != start || meeting.end != end
    meeting.title = title
    meeting.start = min(start, end)
    meeting.end = max(start, end)
    meeting.userAdjusted = meeting.userAdjusted || moved
    store.saveMeeting(meeting)
    if moved { summaries.regenerateMeeting(id) }
  }

  func saveMinutes(_ id: Int64, text: String) {
    guard var meeting = store.meeting(id: id) else { return }
    meeting.minutes = text
    store.saveMeeting(meeting)
  }

  /// "日历是 10:00–10:45，按实际说话延长到 10:48".
  static func boundaryText(_ meeting: Meeting) -> String {
    guard let calendarStart = meeting.calendarStart, let calendarEnd = meeting.calendarEnd else {
      return meeting.origin == .manual ? "手动标记的会议" : "按会议 App 的声音识别"
    }
    if meeting.userAdjusted { return "日历是 \(TimeText.range(calendarStart, calendarEnd))，已手动调整" }
    let calendarText = "日历是 \(TimeText.range(calendarStart, calendarEnd))"
    let sameStart = abs(meeting.start.timeIntervalSince(calendarStart)) < 60
    let sameEnd = abs(meeting.end.timeIntervalSince(calendarEnd)) < 60
    if sameStart && sameEnd { return calendarText }
    if sameStart {
      return calendarText + "，按实际说话\(meeting.end > calendarEnd ? "延长" : "缩短")到 \(TimeText.clock(meeting.end))"
    }
    return calendarText + "，按实际说话调整为 \(TimeText.range(meeting.start, meeting.end))"
  }

  static func sourceText(_ meeting: Meeting) -> String {
    let app = meeting.app ?? "Mac 麦克风"
    switch meeting.origin {
    case .calendar: return "\(app) · 来自日历"
    case .meetingAudio: return app
    case .manual: return "\(app) · 手动标记"
    }
  }

  static func minutes(for meeting: Meeting) -> String {
    let date = Calendar.current.dateComponents([.month, .day], from: meeting.start)
    var text = "\(meeting.title)纪要（\(date.month ?? 0) 月 \(date.day ?? 0) 日 \(TimeText.range(meeting.start, meeting.end))）\n\n要点\n"
    text += meeting.points.map { "· \($0.text)" }.joined(separator: "\n")
    return text
  }
}
