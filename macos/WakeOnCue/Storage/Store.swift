import Foundation
import Observation
import OSLog

/// Everything WakeOnCue keeps, in `~/Library/Application Support/WakeOnCue`: `library.sqlite`
/// for text and metadata, `Audio/<yyyy-MM-dd>/` for the AAC segments.
@Observable
final class Store {
  static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Store")

  nonisolated static var rootDirectory: URL {
    URL.applicationSupportDirectory.appending(path: "WakeOnCue", directoryHint: .isDirectory)
  }

  nonisolated static var audioDirectory: URL {
    rootDirectory.appending(path: "Audio", directoryHint: .isDirectory)
  }

  /// Bumped on every write so views that read through the store refresh.
  private(set) var revision = 0

  @ObservationIgnored private let db: SQLiteDatabase

  init(directory: URL = Store.rootDirectory) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    db = try SQLiteDatabase(url: directory.appending(path: "library.sqlite"))
    try migrate()
  }

  private func migrate() throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS sentence (
        id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, channel TEXT NOT NULL,
        speaker TEXT NOT NULL, source TEXT NOT NULL, text TEXT NOT NULL)
      """)
    try db.execute("CREATE INDEX IF NOT EXISTS sentence_start ON sentence(start)")
    try db.execute("""
      CREATE TABLE IF NOT EXISTS segment (
        id INTEGER PRIMARY KEY, channel TEXT NOT NULL, start REAL NOT NULL, end REAL,
        path TEXT NOT NULL, source TEXT NOT NULL)
      """)
    try db.execute("CREATE INDEX IF NOT EXISTS segment_start ON segment(start)")
    try db.execute("""
      CREATE TABLE IF NOT EXISTS mark (
        id INTEGER PRIMARY KEY, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
        created REAL NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS gap (
        id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL, reason TEXT NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS hour_summary (
        hour REAL PRIMARY KEY, summary TEXT NOT NULL, keys TEXT NOT NULL, generated REAL NOT NULL,
        final INTEGER NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS day_summary (
        day REAL PRIMARY KEY, headline TEXT NOT NULL, details TEXT NOT NULL, generated REAL NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS meeting (
        id INTEGER PRIMARY KEY, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
        origin TEXT NOT NULL, calendar_id TEXT, calendar_start REAL, calendar_end REAL, app TEXT,
        attendees TEXT NOT NULL, points TEXT NOT NULL, minutes TEXT, points_generated REAL,
        adjusted INTEGER NOT NULL DEFAULT 0)
      """)
    // Added after the first release: which engine wrote each summary.
    let sentenceColumns = try db.query("PRAGMA table_info(sentence)") { $0.text(1) }
    if !sentenceColumns.contains("refined_by") {
      try db.execute("ALTER TABLE sentence ADD COLUMN refined_by TEXT")
    }
    if !sentenceColumns.contains("speaker_name") {
      try db.execute("ALTER TABLE sentence ADD COLUMN speaker_name TEXT")
    }
    for table in ["hour_summary", "day_summary", "meeting"] {
      let columns = try db.query("PRAGMA table_info(\(table))") { $0.text(1) }
      if !columns.contains("engine") { try db.execute("ALTER TABLE \(table) ADD COLUMN engine TEXT") }
    }
  }

  private func changed() { revision += 1 }

  private func run(_ sql: String, _ bindings: [SQLiteDatabase.Value] = []) {
    do { try db.execute(sql, bindings) } catch {
      Self.logger.error("SQL failed: \(error.localizedDescription, privacy: .public) — \(sql, privacy: .public)")
    }
  }

  private func fetch<T>(_ sql: String, _ bindings: [SQLiteDatabase.Value] = [], map: (SQLiteDatabase.Row) -> T?) -> [T] {
    do { return try db.query(sql, bindings, map: map) } catch {
      Self.logger.error("SQL failed: \(error.localizedDescription, privacy: .public) — \(sql, privacy: .public)")
      return []
    }
  }

  // MARK: Sentences

  @discardableResult
  func insertSentence(start: Date, end: Date, channel: AudioChannel, speaker: Speaker, source: String, text: String) -> Int64 {
    run(
      "INSERT INTO sentence (start, end, channel, speaker, source, text) VALUES (?, ?, ?, ?, ?, ?)",
      [.date(start), .date(end), .text(channel.rawValue), .text(speaker.rawValue), .text(source), .text(text)])
    let id = db.lastInsertID
    changed()
    return id
  }

  /// A better transcript of the same words; times and speaker stay as they were.
  func refineSentence(id: Int64, text: String, by model: String) {
    run("UPDATE sentence SET text = ?, refined_by = ? WHERE id = ?", [.text(text), .text(model), .int(id)])
    changed()
  }

  /// Who said it, as found from the voice. Times and text stay.
  func setSpeaker(id: Int64, speaker: Speaker, name: String?) {
    run("UPDATE sentence SET speaker = ?, speaker_name = ? WHERE id = ?",
        [.text(speaker.rawValue), name.map { .text($0) } ?? .null, .int(id)])
    changed()
  }

  /// Renames every sentence of a day that carries `old`, e.g. "说话人 2" → "林雨".
  func renameSpeaker(_ old: String, to new: String, in interval: DateInterval) {
    run("UPDATE sentence SET speaker_name = ? WHERE speaker_name = ? AND start >= ? AND start < ?",
        [.text(new), .text(old), .date(interval.start), .date(interval.end)])
    changed()
  }

  func deleteSentence(id: Int64) {
    run("DELETE FROM sentence WHERE id = ?", [.int(id)])
    changed()
  }

  private static let sentenceColumns = "id, start, end, channel, speaker, source, text, refined_by, speaker_name"

  private static func sentence(_ row: SQLiteDatabase.Row) -> Sentence? {
    Sentence(
      id: row.int(0), start: row.date(1), end: row.date(2),
      channel: AudioChannel(rawValue: row.text(3)) ?? .microphone,
      speaker: Speaker(rawValue: row.text(4)) ?? .me,
      source: row.text(5), text: row.text(6), refinedBy: row.isNull(7) ? nil : row.text(7),
      speakerName: row.isNull(8) ? nil : row.text(8))
  }

  /// Every sentence that starts in the interval, including private and deleted ones.
  func sentences(in interval: DateInterval) -> [Sentence] {
    fetch(
      "SELECT \(Self.sentenceColumns) FROM sentence WHERE start >= ? AND start < ? ORDER BY start",
      [.date(interval.start), .date(interval.end)], map: Self.sentence)
  }

  func sentences(ids: [Int64]) -> [Sentence] {
    guard !ids.isEmpty else { return [] }
    let list = ids.map(String.init).joined(separator: ",")
    return fetch("SELECT \(Self.sentenceColumns) FROM sentence WHERE id IN (\(list)) ORDER BY start", map: Self.sentence)
  }

  /// Substring search, newest first. Private and deleted ranges are filtered by the caller.
  func search(_ text: String, limit: Int = 400) -> [Sentence] {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    return fetch(
      "SELECT \(Self.sentenceColumns) FROM sentence WHERE text LIKE ? ESCAPE '\\' ORDER BY start DESC LIMIT ?",
      [.text("%\(escaped)%"), .int(Int64(limit))], map: Self.sentence)
  }

  /// Start of every day that has a recording, for the calendar's dots.
  func recordedDays(in interval: DateInterval) -> Set<Date> {
    let calendar = Calendar.current
    let starts = fetch(
      "SELECT start FROM segment WHERE start >= ? AND start < ?",
      [.date(interval.start), .date(interval.end)]) { $0.date(0) }
    return Set(starts.map { calendar.startOfDay(for: $0) })
  }

  // MARK: Audio segments

  func insertSegment(channel: AudioChannel, start: Date, path: String, source: String) -> Int64 {
    run(
      "INSERT INTO segment (channel, start, end, path, source) VALUES (?, ?, NULL, ?, ?)",
      [.text(channel.rawValue), .date(start), .text(path), .text(source)])
    let id = db.lastInsertID
    changed()
    return id
  }

  func finishSegment(id: Int64, end: Date, source: String) {
    run("UPDATE segment SET end = ?, source = ? WHERE id = ?", [.date(end), .text(source), .int(id)])
    changed()
  }

  func removeSegment(id: Int64) {
    run("DELETE FROM segment WHERE id = ?", [.int(id)])
    changed()
  }

  /// Segments that overlap the interval. An open segment counts as running until now.
  func segments(overlapping interval: DateInterval) -> [AudioSegment] {
    let now = Date().timeIntervalSince1970
    return fetch(
      "SELECT id, channel, start, COALESCE(end, ?), path, source FROM segment WHERE start < ? AND COALESCE(end, ?) > ? ORDER BY start",
      [.double(now), .date(interval.end), .double(now), .date(interval.start)]
    ) { row in
      AudioSegment(
        id: row.int(0), channel: AudioChannel(rawValue: row.text(1)) ?? .microphone,
        start: row.date(2), end: row.date(3), path: row.text(4), source: row.text(5))
    }
  }

  /// Segments left open by a crash; the caller measures their files and closes them.
  func openSegments() -> [AudioSegment] {
    fetch("SELECT id, channel, start, start, path, source FROM segment WHERE end IS NULL") { row in
      AudioSegment(
        id: row.int(0), channel: AudioChannel(rawValue: row.text(1)) ?? .microphone,
        start: row.date(2), end: row.date(3), path: row.text(4), source: row.text(5))
    }
  }

  func segments(endingBefore date: Date) -> [AudioSegment] {
    fetch("SELECT id, channel, start, end, path, source FROM segment WHERE end IS NOT NULL AND end < ?", [.date(date)]) { row in
      AudioSegment(
        id: row.int(0), channel: AudioChannel(rawValue: row.text(1)) ?? .microphone,
        start: row.date(2), end: row.date(3), path: row.text(4), source: row.text(5))
    }
  }

  // MARK: Private and deleted ranges

  func addMark(_ kind: TimeMark.Kind, start: Date, end: Date) {
    run("INSERT INTO mark (kind, start, end, created) VALUES (?, ?, ?, ?)",
        [.text(kind.rawValue), .date(start), .date(end), .date(.now)])
    changed()
  }

  func removeMarks(_ kind: TimeMark.Kind, overlapping interval: DateInterval) {
    run("DELETE FROM mark WHERE kind = ? AND start < ? AND end > ?",
        [.text(kind.rawValue), .date(interval.end), .date(interval.start)])
    changed()
  }

  func removeMark(id: Int64) {
    run("DELETE FROM mark WHERE id = ?", [.int(id)])
    changed()
  }

  func marks(overlapping interval: DateInterval? = nil) -> [TimeMark] {
    let interval = interval ?? DateInterval(start: .distantPast, end: .distantFuture)
    return fetch(
      "SELECT id, kind, start, end, created FROM mark WHERE start < ? AND end > ? ORDER BY start",
      [.date(interval.end), .date(interval.start)]
    ) { row in
      TimeMark(
        id: row.int(0), kind: TimeMark.Kind(rawValue: row.text(1)) ?? .deleted,
        start: row.date(2), end: row.date(3), createdAt: row.date(4))
    }
  }

  /// Removes everything recorded in the range: sentences, audio files and summaries.
  func purge(_ interval: DateInterval) {
    for segment in segments(overlapping: interval) where segment.start >= interval.start && segment.end <= interval.end {
      try? FileManager.default.removeItem(at: Store.audioDirectory.appending(path: segment.path))
      run("DELETE FROM segment WHERE id = ?", [.int(segment.id)])
    }
    run("DELETE FROM sentence WHERE start >= ? AND start < ?", [.date(interval.start), .date(interval.end)])
    run("DELETE FROM hour_summary WHERE hour >= ? AND hour < ?", [.date(interval.start), .date(interval.end)])
    changed()
  }

  // MARK: Capture gaps

  func openGap(start: Date, reason: String) -> Int64 {
    run("INSERT INTO gap (start, end, reason) VALUES (?, NULL, ?)", [.date(start), .text(reason)])
    let id = db.lastInsertID
    changed()
    return id
  }

  func closeGap(id: Int64, end: Date) {
    run("UPDATE gap SET end = ? WHERE id = ?", [.date(end), .int(id)])
    changed()
  }

  func closeOpenGaps(at end: Date) {
    run("UPDATE gap SET end = ? WHERE end IS NULL", [.date(end)])
  }

  func gaps(overlapping interval: DateInterval) -> [CaptureGap] {
    let now = Date().timeIntervalSince1970
    return fetch(
      "SELECT id, start, end, reason FROM gap WHERE start < ? AND COALESCE(end, ?) > ? ORDER BY start",
      [.date(interval.end), .double(now), .date(interval.start)]
    ) { row in
      CaptureGap(id: row.int(0), start: row.date(1), end: row.optionalDate(2), reason: row.text(3))
    }
  }

  // MARK: Summaries

  func saveHourSummary(_ summary: HourSummary) {
    run(
      "INSERT OR REPLACE INTO hour_summary (hour, summary, keys, generated, final, engine) VALUES (?, ?, ?, ?, ?, ?)",
      [.date(summary.hourStart), .text(summary.summary), .json(summary.keySentenceIDs),
       .date(summary.generatedAt), .int(summary.isFinal ? 1 : 0), summary.engine.map { .text($0) } ?? .null])
    changed()
  }

  func removeHourSummary(hourStart: Date) {
    run("DELETE FROM hour_summary WHERE hour = ?", [.date(hourStart)])
    changed()
  }

  func hourSummaries(in interval: DateInterval) -> [Date: HourSummary] {
    let rows = fetch(
      "SELECT hour, summary, keys, generated, final, engine FROM hour_summary WHERE hour >= ? AND hour < ?",
      [.date(interval.start), .date(interval.end)]
    ) { row in
      HourSummary(
        hourStart: row.date(0), summary: row.text(1), keySentenceIDs: row.json(2, as: [Int64].self) ?? [],
        generatedAt: row.date(3), isFinal: row.int(4) != 0, engine: row.isNull(5) ? nil : row.text(5))
    }
    return Dictionary(rows.map { ($0.hourStart, $0) }, uniquingKeysWith: { $1 })
  }

  func saveDaySummary(_ summary: DaySummary) {
    run(
      "INSERT OR REPLACE INTO day_summary (day, headline, details, generated, engine) VALUES (?, ?, ?, ?, ?)",
      [.date(summary.day), .json(summary.headline), .json(summary.details), .date(summary.generatedAt),
       summary.engine.map { .text($0) } ?? .null])
    changed()
  }

  func daySummary(for day: Date) -> DaySummary? {
    fetch("SELECT day, headline, details, generated, engine FROM day_summary WHERE day = ?", [.date(day)]) { row in
      guard let headline = row.json(1, as: CitedLine.self) else { return nil }
      return DaySummary(
        day: row.date(0), headline: headline, details: row.json(2, as: [CitedLine].self) ?? [],
        generatedAt: row.date(3), engine: row.isNull(4) ? nil : row.text(4))
    }.first
  }

  // MARK: Meetings

  private static let meetingColumns =
    "id, title, start, end, origin, calendar_id, calendar_start, calendar_end, app, attendees, points, minutes, points_generated, adjusted, engine"

  private static func meeting(_ row: SQLiteDatabase.Row) -> Meeting? {
    Meeting(
      id: row.int(0), title: row.text(1), start: row.date(2), end: row.date(3),
      origin: Meeting.Origin(rawValue: row.text(4)) ?? .manual,
      calendarEventID: row.isNull(5) ? nil : row.text(5),
      calendarStart: row.optionalDate(6), calendarEnd: row.optionalDate(7),
      app: row.isNull(8) ? nil : row.text(8),
      attendees: row.json(9, as: [Attendee].self) ?? [],
      points: row.json(10, as: [CitedLine].self) ?? [],
      minutes: row.isNull(11) ? nil : row.text(11),
      pointsGeneratedAt: row.optionalDate(12),
      userAdjusted: row.int(13) != 0,
      pointsEngine: row.isNull(14) ? nil : row.text(14))
  }

  func meetings(overlapping interval: DateInterval) -> [Meeting] {
    fetch(
      "SELECT \(Self.meetingColumns) FROM meeting WHERE start < ? AND end > ? ORDER BY start",
      [.date(interval.end), .date(interval.start)], map: Self.meeting)
  }

  func meeting(id: Int64) -> Meeting? {
    fetch("SELECT \(Self.meetingColumns) FROM meeting WHERE id = ?", [.int(id)], map: Self.meeting).first
  }

  func meeting(calendarEventID: String, day: Date) -> Meeting? {
    let interval = Calendar.current.dateInterval(of: .day, for: day)!
    return fetch(
      "SELECT \(Self.meetingColumns) FROM meeting WHERE calendar_id = ? AND start < ? AND end > ?",
      [.text(calendarEventID), .date(interval.end.addingTimeInterval(86_400)), .date(interval.start.addingTimeInterval(-86_400))],
      map: Self.meeting
    ).first
  }

  @discardableResult
  func saveMeeting(_ meeting: Meeting) -> Int64 {
    let values: [SQLiteDatabase.Value] = [
      .text(meeting.title), .date(meeting.start), .date(meeting.end), .text(meeting.origin.rawValue),
      meeting.calendarEventID.map { .text($0) } ?? .null, .optionalDate(meeting.calendarStart),
      .optionalDate(meeting.calendarEnd), meeting.app.map { .text($0) } ?? .null,
      .json(meeting.attendees), .json(meeting.points), meeting.minutes.map { .text($0) } ?? .null,
      .optionalDate(meeting.pointsGeneratedAt), .int(meeting.userAdjusted ? 1 : 0),
      meeting.pointsEngine.map { .text($0) } ?? .null,
    ]
    if meeting.id == 0 {
      run(
        "INSERT INTO meeting (title, start, end, origin, calendar_id, calendar_start, calendar_end, app, attendees, points, minutes, points_generated, adjusted, engine) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        values)
      changed()
      return db.lastInsertID
    }
    run(
      "UPDATE meeting SET title = ?, start = ?, end = ?, origin = ?, calendar_id = ?, calendar_start = ?, calendar_end = ?, app = ?, attendees = ?, points = ?, minutes = ?, points_generated = ?, adjusted = ?, engine = ? WHERE id = ?",
      values + [.int(meeting.id)])
    changed()
    return meeting.id
  }

  func deleteMeeting(id: Int64) {
    run("DELETE FROM meeting WHERE id = ?", [.int(id)])
    changed()
  }

  // MARK: Storage use

  func textBytes() -> Int64 {
    let url = Store.rootDirectory.appending(path: "library.sqlite")
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return Int64(size)
  }
}
