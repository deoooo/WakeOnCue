import Foundation
import Observation
import OSLog

/// Everything WakeOnCue keeps, in `~/Library/Application Support/WakeOnCue`: `library.sqlite`
/// for text and metadata, `Audio/<yyyy-MM-dd>/` for the AAC segments.
@Observable
final class Store {
  static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Store")

  nonisolated static var rootDirectory: URL {
    #if DEBUG
      // Development aid: a copy of the library, so a test build never touches the real one.
      if let path = ProcessInfo.processInfo.environment["WAKEONCUE_DATA_DIR"], !path.isEmpty {
        return URL(filePath: path, directoryHint: .isDirectory)
      }
    #endif
    return URL.applicationSupportDirectory.appending(path: "WakeOnCue", directoryHint: .isDirectory)
  }

  nonisolated static var audioDirectory: URL {
    rootDirectory.appending(path: "Audio", directoryHint: .isDirectory)
  }

  /// Bumped on every write so views that read through the store refresh.
  private(set) var revision = 0

  @ObservationIgnored private let db: SQLiteDatabase
  /// The library folder this instance owns, so repairs and tests never fall back to the real one.
  @ObservationIgnored private let dataDirectory: URL

  var audioDirectory: URL { dataDirectory.appending(path: "Audio", directoryHint: .isDirectory) }

  init(directory: URL = Store.rootDirectory, readOnly: Bool = false) throws {
    dataDirectory = directory
    if readOnly {
      db = try SQLiteDatabase(url: directory.appending(path: "library.sqlite"), readOnly: true)
      return
    }
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
      CREATE TABLE IF NOT EXISTS remote_segment (
        id TEXT PRIMARY KEY, device TEXT NOT NULL, source TEXT NOT NULL, recording TEXT NOT NULL,
        idx INTEGER NOT NULL, start REAL NOT NULL, duration REAL NOT NULL, path TEXT NOT NULL,
        received REAL NOT NULL, merged INTEGER NOT NULL DEFAULT 0)
      """)
    let remoteColumns = try db.query("PRAGMA table_info(remote_segment)") { $0.text(1) }
    if !remoteColumns.contains("outcome") {
      try db.execute("ALTER TABLE remote_segment ADD COLUMN outcome TEXT")
      try db.execute("ALTER TABLE remote_segment ADD COLUMN clock_offset REAL")
    }
    // Added after the first release: which engine wrote each summary.
    let sentenceColumns = try db.query("PRAGMA table_info(sentence)") { $0.text(1) }
    if !sentenceColumns.contains("refined_by") {
      try db.execute("ALTER TABLE sentence ADD COLUMN refined_by TEXT")
    }
    if !sentenceColumns.contains("speaker_name") {
      try db.execute("ALTER TABLE sentence ADD COLUMN speaker_name TEXT")
    }
    // Added with background re-transcription: retries survive restarts.
    if !sentenceColumns.contains("refine_attempts") {
      try db.execute("ALTER TABLE sentence ADD COLUMN refine_attempts INTEGER NOT NULL DEFAULT 0")
    }
    if !sentenceColumns.contains("refine_next") {
      try db.execute("ALTER TABLE sentence ADD COLUMN refine_next REAL")
    }
    if !sentenceColumns.contains("refine_checked_by") {
      try db.execute("ALTER TABLE sentence ADD COLUMN refine_checked_by TEXT")
    }
    // Watch and iPhone marks, in the device's clock; `clock_offset` moves them onto the Mac's.
    try db.execute("""
      CREATE TABLE IF NOT EXISTS device_mark (
        id TEXT PRIMARY KEY, device TEXT NOT NULL, source TEXT NOT NULL, recording TEXT NOT NULL,
        start REAL NOT NULL, end REAL, tag TEXT, title TEXT, clock_offset REAL NOT NULL DEFAULT 0,
        received REAL NOT NULL)
      """)
    try db.execute("CREATE INDEX IF NOT EXISTS device_mark_start ON device_mark(start)")
    for table in ["hour_summary", "day_summary"] {
      let columns = try db.query("PRAGMA table_info(\(table))") { $0.text(1) }
      if !columns.contains("engine") { try db.execute("ALTER TABLE \(table) ADD COLUMN engine TEXT") }
    }    // Titles the user gave conversations on the iPhone, by conversation ID and its day.
    try db.execute("""
      CREATE TABLE IF NOT EXISTS conversation_title (
        id TEXT PRIMARY KEY, day TEXT NOT NULL, title TEXT NOT NULL, updated REAL NOT NULL)
      """)
    // Edits already applied, so one resent by a phone is applied once.
    try db.execute("CREATE TABLE IF NOT EXISTS applied_edit (id TEXT PRIMARY KEY, applied REAL NOT NULL)")
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
  func refineSentence(id: Int64, text: String, by model: String?) {
    run(
      "UPDATE sentence SET text = ?, refined_by = ?, refine_next = NULL, refine_checked_by = NULL WHERE id = ?",
      [.text(text), model.map { .text($0) } ?? .null, .int(id)])
    changed()
  }

  /// A failed re-transcription: remember the attempt and when to try again. A manually
  /// re-transcribed sentence may still carry its old `refined_by` marker; clear it so the
  /// background sweep can see the failed try even when the sentence was refined before.
  func recordRefineFailure(id: Int64, attempt: Int, next: Date?) {
    run("""
      UPDATE sentence
      SET refine_attempts = ?, refine_next = ?, refined_by = NULL, refine_checked_by = NULL
      WHERE id = ?
      """,
      [.int(Int64(attempt)), .optionalDate(next), .int(id)])
    changed()
  }

  /// Counts one failure from the latest stored state, not from a queued job's old snapshot.
  @discardableResult
  func bumpRefineFailure(id: Int64, now: Date = .now) -> Int {
    guard let current = sentences(ids: [id]).first else { return 0 }
    let attempt = current.refineAttempts + 1
    recordRefineFailure(id: id, attempt: attempt, next: RefineSchedule.nextTry(after: attempt, now: now))
    return attempt
  }

  /// The chosen model looked at this sentence and decided the live words are better. A later
  /// model does not need to check it again.
  func markRefineChecked(id: Int64, model: String) {
    run("UPDATE sentence SET refine_checked_by = ? WHERE id = ?", [.text(model), .int(id)])
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

  /// A tiny unnamed cluster that could not be merged into anyone else: back to plain "他人".
  func revertSpeaker(name: String, in interval: DateInterval) {
    run("UPDATE sentence SET speaker = 'other', speaker_name = NULL WHERE speaker_name = ? AND start >= ? AND start < ?",
        [.text(name), .date(interval.start), .date(interval.end)])
    changed()
  }

  /// Puts back to "我" the microphone sentences whose speaker was never named by hand: no name,
  /// or an auto-generated "说话人 N". Returns the hours that changed, for their summaries.
  func resetUnnamedMicrophoneSpeakers(in interval: DateInterval) -> [Date] {
    let condition = """
      channel = 'microphone' AND start >= ? AND start < ?
        AND (speaker_name IS NULL OR speaker_name = '' OR speaker_name LIKE '说话人 %')
        AND (speaker <> 'me' OR speaker_name IS NOT NULL)
      """
    let starts = fetch("SELECT DISTINCT start FROM sentence WHERE \(condition)",
                       [.date(interval.start), .date(interval.end)]) { $0.date(0) }
    guard !starts.isEmpty else { return [] }
    run("UPDATE sentence SET speaker = 'me', speaker_name = NULL WHERE \(condition)",
        [.date(interval.start), .date(interval.end)])
    return Set(starts.map { Calendar.current.hourStart($0) }).sorted()
  }

  func deleteSentence(id: Int64) {
    run("DELETE FROM sentence WHERE id = ?", [.int(id)])
    changed()
  }

  /// The sentence columns, with defaults for a read-only library that has not been through the
  /// latest migration yet (the CLI may open a library before the app has been launched again).
  private var sentenceColumns: String {
    let columns = (try? db.query("PRAGMA table_info(sentence)") { $0.text(1) }) ?? []
    func value(_ name: String, fallback: String) -> String {
      columns.contains(name) ? name : "\(fallback) AS \(name)"
    }
    return "id, start, end, channel, speaker, source, text, "
      + "\(value("refined_by", fallback: "NULL")), \(value("speaker_name", fallback: "NULL")), "
      + "\(value("refine_attempts", fallback: "0")), \(value("refine_next", fallback: "NULL")), "
      + "\(value("refine_checked_by", fallback: "NULL"))"
  }

  private static func sentence(_ row: SQLiteDatabase.Row) -> Sentence? {
    Sentence(
      id: row.int(0), start: row.date(1), end: row.date(2),
      channel: AudioChannel(rawValue: row.text(3)) ?? .microphone,
      speaker: Speaker(rawValue: row.text(4)) ?? .me,
      source: row.text(5), text: row.text(6), refinedBy: row.isNull(7) ? nil : row.text(7),
      speakerName: row.isNull(8) ? nil : row.text(8),
      refineAttempts: Int(row.int(9)), refineNext: row.optionalDate(10),
      refineCheckedBy: row.isNull(11) ? nil : row.text(11))
  }

  /// Sentences the background sweep should re-transcribe with `model`, oldest first. Missing are
  /// private or deleted sentences, ones another model already checked, ones out of tries or still
  /// waiting for their backoff, and sentences that are too old or too recent to have audio yet.
  func sentencesNeedingRefinement(
    model: String, now: Date = .now, limit: Int = 200, maxAttempts: Int = 4
  ) -> [Sentence] {
    let oldest = now.addingTimeInterval(-RefineSchedule.maximumAge)
    let settled = now.addingTimeInterval(-RefineSchedule.settle)
    return fetch(
      """
      SELECT \(sentenceColumns) FROM sentence
      WHERE refined_by IS NULL
        AND (refine_checked_by IS NULL OR refine_checked_by <> ?)
        AND refine_attempts < ?
        AND (refine_next IS NULL OR refine_next <= ?)
        AND start >= ? AND end <= ?
        AND NOT EXISTS (
          SELECT 1 FROM mark
          WHERE mark.kind IN ('private', 'deleted', 'paused')
            AND mark.start < sentence.end AND mark.end > sentence.start)
      ORDER BY start
      LIMIT ?
      """,
      [.text(model), .int(Int64(maxAttempts)), .date(now), .date(oldest), .date(settled), .int(Int64(limit))],
      map: Self.sentence)
  }

  /// How many sentences in the interval no model has handled yet, and how many of those are
  /// longer than 2.5 seconds. A sentence a model looked at and kept the live words for
  /// (`refine_checked_by`) is handled, not waiting. Private and deleted sentences are left out, as
  /// in `sentencesNeedingRefinement`.
  func unrefinedCounts(in interval: DateInterval) -> (total: Int, overTwoSeconds: Int) {
    let rows = fetch(
      """
      SELECT COUNT(*), COALESCE(SUM(CASE WHEN end - start > 2.5 THEN 1 ELSE 0 END), 0)
      FROM sentence
      WHERE refined_by IS NULL AND refine_checked_by IS NULL AND start >= ? AND start < ?
        AND NOT EXISTS (
          SELECT 1 FROM mark
          WHERE mark.kind IN ('private', 'deleted', 'paused')
            AND mark.start < sentence.end AND mark.end > sentence.start)
      """,
      [.date(interval.start), .date(interval.end)]
    ) { row in (Int(row.int(0)), Int(row.int(1))) }
    return rows.first ?? (0, 0)
  }

  /// Every sentence that starts in the interval, including private and deleted ones.
  func sentences(in interval: DateInterval) -> [Sentence] {
    fetch(
      "SELECT \(sentenceColumns) FROM sentence WHERE start >= ? AND start < ? ORDER BY start",
      [.date(interval.start), .date(interval.end)], map: Self.sentence)
  }

  func sentences(ids: [Int64]) -> [Sentence] {
    guard !ids.isEmpty else { return [] }
    let list = ids.map(String.init).joined(separator: ",")
    return fetch("SELECT \(sentenceColumns) FROM sentence WHERE id IN (\(list)) ORDER BY start", map: Self.sentence)
  }

  /// Substring search, newest first. Private and deleted ranges are filtered by the caller.
  func search(_ text: String, limit: Int = 400) -> [Sentence] {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    return fetch(
      "SELECT \(sentenceColumns) FROM sentence WHERE text LIKE ? ESCAPE '\\' ORDER BY start DESC LIMIT ?",
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
      // A segment still being written ends "now", but never before its own start: the sample
      // clock it was opened with may be a moment ahead of the wall clock.
      "SELECT id, channel, start, MAX(COALESCE(end, ?), start), path, source FROM segment WHERE start < ? AND MAX(COALESCE(end, ?), start) > ? ORDER BY start",
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

  /// Ends open marks of a kind, e.g. a pause when recording resumes.
  func closeMarks(_ kind: TimeMark.Kind, at end: Date) {
    run("UPDATE mark SET end = ? WHERE kind = ? AND end > ? AND start <= ?",
        [.date(end), .text(kind.rawValue), .date(end), .date(end)])
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
    run("DELETE FROM device_mark WHERE start + clock_offset >= ? AND start + clock_offset < ?",
        [.date(interval.start), .date(interval.end)])
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

  // MARK: Audio from other devices

  /// A segment received from a phone, waiting to be merged into the timeline.
  func insertRemoteSegment(_ info: SyncProtocol.SegmentInfo, device: String, path: String) {
    run(
      "INSERT OR REPLACE INTO remote_segment (id, device, source, recording, idx, start, duration, path, received, merged) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
      [.text(info.id), .text(device), .text(info.source), .text(info.recordingID), .int(Int64(info.index)),
       .date(info.startedAt), .double(info.duration), .text(path), .date(.now)])
    changed()
  }

  nonisolated struct RemoteSegment: Sendable {
    var id: String
    var device: String
    var source: String
    var start: Date
    var duration: TimeInterval
    var path: String
  }

  func unmergedRemoteSegments() -> [RemoteSegment] {
    fetch("SELECT id, device, source, start, duration, path FROM remote_segment WHERE merged = 0 ORDER BY start") { row in
      RemoteSegment(id: row.text(0), device: row.text(1), source: row.text(2), start: row.date(3), duration: row.double(4), path: row.text(5))
    }
  }

  /// Records what merging did with a segment: "filled", "duplicate", "kept", "dropped".
  func finishRemoteSegment(id: String, outcome: String, clockOffset: TimeInterval?) {
    run("UPDATE remote_segment SET merged = 1, outcome = ?, clock_offset = ? WHERE id = ?",
        [.text(outcome), clockOffset.map { .double($0) } ?? .null, .text(id)])
    // Marks of the same recording follow the offset its audio was placed with.
    if let clockOffset {
      run("""
        UPDATE device_mark SET clock_offset = ?
        WHERE (device, recording) IN (SELECT device, recording FROM remote_segment WHERE id = ?)
        """, [.double(clockOffset), .text(id)])
    }
    changed()
  }

  func hasRemoteSegment(id: String) -> Bool {
    !fetch("SELECT 1 FROM remote_segment WHERE id = ?", [.text(id)]) { _ in true }.isEmpty
  }

  /// Segments received per device and how many still wait to be merged.
  func remoteSegmentCounts() -> [String: (total: Int, waiting: Int, latest: Date?)] {
    let rows = fetch("SELECT device, COUNT(*), SUM(merged = 0), MAX(start + duration) FROM remote_segment GROUP BY device") { row in
      (row.text(0), Int(row.int(1)), Int(row.int(2)), row.optionalDate(3))
    }
    return Dictionary(rows.map { ($0.0, (total: $0.1, waiting: $0.2, latest: $0.3)) }, uniquingKeysWith: { a, _ in a })
  }

  /// When the latest Watch audio received ends, if any came.
  func latestWatchAudio() -> Date? {
    fetch("SELECT MAX(start + duration) FROM remote_segment WHERE source = 'watch'") { $0.optionalDate(0) }.first ?? nil
  }

  // MARK: Watch and iPhone marks

  /// Stores or updates marks from a phone and returns them on the Mac's timeline. Each takes the
  /// clock offset its recording's audio was merged with, or `clockOffset` (the device's) when
  /// none of that audio is merged yet.
  @discardableResult
  func saveDeviceMarks(_ marks: [SyncProtocol.MarkInfo], device: String, clockOffset: TimeInterval) -> [DeviceMark] {
    guard !marks.isEmpty else { return [] }
    for mark in marks {
      let merged = fetch(
        "SELECT clock_offset FROM remote_segment WHERE device = ? AND recording = ? AND clock_offset IS NOT NULL ORDER BY start DESC LIMIT 1",
        [.text(device), .text(mark.recordingID)]) { $0.double(0) }.first
      run(
        "INSERT OR REPLACE INTO device_mark (id, device, source, recording, start, end, tag, title, clock_offset, received) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [.text(mark.id), .text(device), .text(mark.source), .text(mark.recordingID), .date(mark.start),
         .optionalDate(mark.end), mark.tag.map { .text($0) } ?? .null, mark.title.map { .text($0) } ?? .null,
         .double(merged ?? clockOffset), .date(.now)])
    }
    changed()
    return deviceMarks(ids: marks.map(\.id))
  }

  private static let deviceMarkColumns =
    "id, source, recording, start + clock_offset, CASE WHEN end IS NULL THEN NULL ELSE end + clock_offset END, tag, title"

  private static func deviceMark(_ row: SQLiteDatabase.Row) -> DeviceMark? {
    DeviceMark(
      id: row.text(0), source: row.text(1), recordingID: row.text(2), start: row.date(3), end: row.optionalDate(4),
      tag: row.isNull(5) ? nil : DeviceMark.Tag(rawValue: row.text(5)), title: row.isNull(6) ? nil : row.text(6))
  }

  /// Marks that touch the interval, on the Mac's timeline, including those in private and
  /// deleted ranges: the caller hides those.
  func deviceMarks(overlapping interval: DateInterval) -> [DeviceMark] {
    fetch(
      "SELECT \(Self.deviceMarkColumns) FROM device_mark WHERE start + clock_offset < ? AND COALESCE(end, start) + clock_offset >= ? ORDER BY start + clock_offset",
      [.date(interval.end), .date(interval.start)], map: Self.deviceMark)
  }

  func deviceMarks(ids: [String]) -> [DeviceMark] {
    guard !ids.isEmpty else { return [] }
    let marks = ids.map { _ in "?" }.joined(separator: ",")
    return fetch(
      "SELECT \(Self.deviceMarkColumns) FROM device_mark WHERE id IN (\(marks)) ORDER BY start + clock_offset",
      ids.map { .text($0) }, map: Self.deviceMark)
  }

  // MARK: Conversations for the iPhone

  /// A cheap fingerprint of every day with sentences, from aggregates the database keeps an index
  /// for. It changes when sentences are added, removed, re-transcribed or given a speaker.
  func sentenceDaySignatures() -> [String: String] {
    let rows = fetch("""
      SELECT strftime('%Y-%m-%d', start, 'unixepoch', 'localtime') AS d, COUNT(*), MIN(id), MAX(id),
        TOTAL(length(text)), TOTAL(end - start), SUM(speaker = 'me'), COUNT(refined_by),
        COUNT(refine_checked_by), COUNT(speaker_name), GROUP_CONCAT(DISTINCT speaker_name)
      FROM sentence GROUP BY d
      """) { row in
      (row.text(0), (1...10).map { row.isNull(Int32($0)) ? "-" : row.text(Int32($0)) }.joined(separator: "|"))
    }
    return Dictionary(rows, uniquingKeysWith: { a, _ in a })
  }

  /// Per day, the phone's own audio the Mac has merged, so a day changes for that phone when its
  /// recordings become part of the Mac's conversations.
  func remoteDaySignatures(device: String) -> [String: String] {
    let rows = fetch("""
      SELECT strftime('%Y-%m-%d', start + COALESCE(clock_offset, 0), 'unixepoch', 'localtime') AS d,
        COUNT(*), TOTAL(COALESCE(clock_offset, 0)), SUM(merged)
      FROM remote_segment WHERE device = ? GROUP BY d
      """, [.text(device)]) { row in (row.text(0), "\(row.int(1))|\(row.double(2))|\(row.int(3))") }
    return Dictionary(rows, uniquingKeysWith: { a, _ in a })
  }

  /// The phone's recordings whose merged audio touches the interval, on the Mac's timeline.
  func remoteRecordings(device: String, overlapping interval: DateInterval) -> [(source: String, recordingID: String, start: Date, end: Date)] {
    fetch("""
      SELECT source, recording, start + COALESCE(clock_offset, 0), start + COALESCE(clock_offset, 0) + duration
      FROM remote_segment WHERE device = ? AND merged = 1 AND outcome != 'dropped'
        AND start + COALESCE(clock_offset, 0) < ? AND start + COALESCE(clock_offset, 0) + duration > ?
      """, [.text(device), .date(interval.end), .date(interval.start)]
    ) { row in (row.text(0), row.text(1), row.date(2), row.date(3)) }
  }

  func conversationTitles(day: String) -> [String: String] {
    let rows = fetch("SELECT id, title FROM conversation_title WHERE day = ?", [.text(day)]) { ($0.text(0), $0.text(1)) }
    return Dictionary(rows, uniquingKeysWith: { a, _ in a })
  }

  func conversationTitleSignatures() -> [String: String] {
    let rows = fetch("SELECT day, GROUP_CONCAT(id || '=' || title, ';') FROM conversation_title GROUP BY day") {
      ($0.text(0), $0.text(1))
    }
    return Dictionary(rows, uniquingKeysWith: { a, _ in a })
  }

  func setConversationTitle(id: String, day: String, title: String?) {
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      run("INSERT OR REPLACE INTO conversation_title (id, day, title, updated) VALUES (?, ?, ?, ?)",
          [.text(id), .text(day), .text(title), .date(.now)])
    } else {
      run("DELETE FROM conversation_title WHERE id = ?", [.text(id)])
    }
    changed()
  }

  /// Records an edit as applied; false when it already was.
  func claimEdit(id: String) -> Bool {
    guard fetch("SELECT 1 FROM applied_edit WHERE id = ?", [.text(id)], map: { _ in true }).isEmpty else { return false }
    run("INSERT INTO applied_edit (id, applied) VALUES (?, ?)", [.text(id), .date(.now)])
    return true
  }

  // MARK: Storage use

  func textBytes() -> Int64 {
    let url = Store.rootDirectory.appending(path: "library.sqlite")
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return Int64(size)
  }
}
