import Foundation

/// Reads what an export needs. Shared by the app and the `wakeoncue export` command.
extension ExportSource {
  static func day(_ day: Date, store: Store, calendar: Calendar = .current) -> ExportSource {
    let start = calendar.startOfDay(for: day)
    let range = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    return ExportSource(
      scope: .day, range: range, sentences: store.sentences(in: range), marks: store.marks(overlapping: range),
      daySummary: store.daySummary(for: start), hourSummaries: Array(store.hourSummaries(in: range).values),
      meetings: store.meetings(overlapping: range))
  }

  static func hour(_ hour: Date, store: Store, calendar: Calendar = .current) -> ExportSource {
    let range = calendar.dateInterval(of: .hour, for: hour)!
    return ExportSource(
      scope: .hour, range: range, sentences: store.sentences(in: range), marks: store.marks(overlapping: range),
      hourSummaries: Array(store.hourSummaries(in: range).values))
  }

  static func meeting(_ meeting: Meeting, store: Store) -> ExportSource {
    let range = DateInterval(start: meeting.start, end: max(meeting.end, meeting.start))
    return ExportSource(
      scope: .meeting(meeting), range: range, sentences: store.sentences(in: range), marks: store.marks(overlapping: range))
  }
}
