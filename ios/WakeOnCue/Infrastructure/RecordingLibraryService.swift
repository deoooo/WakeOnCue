import Foundation
import WakeOnCueCore

struct RecordingLibrarySearchResult: Sendable {
  let recordings: [RecordingRecord]
  let transcriptFilesSearched: Int
  let recordingsWithoutLocalTranscript: Int
  let transcriptErrors: [String]
}

actor RecordingLibraryService {
  private let layout: RecordingFileLayout
  private let store: RecordingStore
  /// Where audio waits for the paired Mac; nil for the app's own outbox.
  private let macOutboxRoot: URL?
  /// Where Watch audio arrives; nil for the app's own inbox.
  private let watchInboxRoot: URL?

  init(layout: RecordingFileLayout, macOutboxRoot: URL? = nil, watchInboxRoot: URL? = nil) throws {
    self.layout = layout
    self.macOutboxRoot = macOutboxRoot
    self.watchInboxRoot = watchInboxRoot
    store = try RecordingStore(databaseURL: layout.databaseURL)
  }

  init(
    layout: RecordingFileLayout, store: RecordingStore, macOutboxRoot: URL? = nil,
    watchInboxRoot: URL? = nil
  ) {
    self.layout = layout
    self.store = store
    self.macOutboxRoot = macOutboxRoot
    self.watchInboxRoot = watchInboxRoot
  }

  func page(limit: Int, offset: Int) async throws -> [RecordingRecord] {
    try await store.recordings(limit: limit, offset: offset)
  }

  /// Recordings that started within `interval`, newest first. The store lists recordings by when
  /// they were saved, which is never before they started, so paging stops once a page reaches
  /// recordings saved before the interval.
  func recordings(startedIn interval: DateInterval, pageSize: Int = 100) async throws
    -> [RecordingRecord]
  {
    let safePageSize = max(1, pageSize)
    var result: [RecordingRecord] = []
    var offset = 0
    while true {
      try Task.checkCancellation()
      let page = try await store.recordings(limit: safePageSize, offset: offset)
      // The end is exclusive: a recording starting at midnight belongs to the next day only.
      result.append(
        contentsOf: page.filter { $0.startedAt >= interval.start && $0.startedAt < interval.end })
      guard page.count == safePageSize, let last = page.last, last.createdAt >= interval.start
      else { break }
      offset += safePageSize
    }
    return result.sorted { $0.startedAt > $1.startedAt }
  }

  func count() async throws -> Int {
    try await store.recordingCount()
  }

  func recording(id: String) async throws -> RecordingRecord {
    try await store.recording(id: id)
  }

  func saveTitle(_ title: String?, for recordingID: String) async throws -> RecordingRecord {
    try await store.updateRecordingTitle(recordingID: recordingID, title: title)
  }

  func moveToTrash(recordingID: String) async throws {
    try await store.moveRecordingToTrash(recordingID: recordingID)
  }

  func restore(recordingID: String) async throws {
    try await store.restoreRecording(recordingID: recordingID)
  }

  func deletedRecordings() async throws -> [RecordingRecord] {
    try await store.deletedRecordings()
  }

  /// Rows go first, in one transaction, so Recover can never return a recording with some of
  /// its files gone. Files that fail to go here are removed by `removeFilesOfDeletedRecordings`.
  func deletePermanently(recordingID: String) async throws {
    try await store.removeDeletedRecording(recordingID: recordingID)
    try? layout.removeFiles(recordingID: recordingID)
    // The outbox holds its own link to the audio, which would otherwise still reach the Mac.
    MacOutbox.remove(appRecordingID: recordingID, root: macOutboxRoot)
    // Late Watch segments of this recording would otherwise wait for the next import.
    WatchSessionInbox.removeFolders(ofRecordings: [recordingID], root: watchInboxRoot)
  }

  /// Whether a recording's audio may go to the paired Mac. A Watch segment can be queued
  /// before its recording exists, so an unknown recording is sent.
  func macForwardingDisposition(recordingID: String) async -> MacOutbox.Disposition {
    do {
      return try await store.recording(id: recordingID).isDeleted ? .hold : .send
    } catch RecordingStoreError.notFound {
      return (try? await store.wasPermanentlyDeleted(recordingID: recordingID)) == true ? .discard : .send
    } catch {
      // Unsure is not a reason to send audio the user may have deleted; the next sync decides.
      return .hold
    }
  }

  /// Removes what remains of permanently deleted recordings: files that failed to go, and
  /// folders that late writes, such as a bookmark tag from the Watch, created again.
  func removeFilesOfDeletedRecordings() async throws {
    let recordingIDs = try await store.permanentlyDeletedRecordingIDs()
    for recordingID in recordingIDs {
      try? layout.removeFiles(recordingID: recordingID)
    }
    // Late Watch segments are queued for the Mac as they arrive, before anything can check them.
    let deleted = Set(recordingIDs)
    WatchSessionInbox.removeFolders(ofRecordings: deleted, root: watchInboxRoot)
    for item in MacOutbox.items(root: macOutboxRoot)
    where deleted.contains(MacOutbox.appRecordingID(for: item.info)) {
      MacOutbox.remove(item)
    }
  }

  /// Permanently deletes recordings past the retention period and returns their identifiers.
  /// Deleting needs two runs a day apart, because the only clock here is one the user can set:
  /// a date moved forward and back again deletes nothing. One that fails is retried next time.
  @discardableResult
  func purgeExpiredRecordings(now: Date = Date()) async throws -> [String] {
    var purged: [String] = []
    for recording in try await store.deletedRecordings() {
      guard let deletedAt = recording.deletedAt, deletedAt <= now else {
        try? await store.restartTrashRetention(recordingID: recording.id, now: now)
        continue
      }
      guard now.timeIntervalSince(deletedAt) >= RecordingStore.trashRetention else {
        if recording.trashExpirySeenAt != nil {
          try? await store.setTrashExpirySeen(recordingID: recording.id, at: nil, now: now)
        }
        continue
      }
      guard let seenAt = recording.trashExpirySeenAt, seenAt <= now else {
        try? await store.setTrashExpirySeen(recordingID: recording.id, at: now, now: now)
        continue
      }
      guard now.timeIntervalSince(seenAt) >= RecordingStore.trashPurgeConfirmationDelay else {
        continue
      }
      guard (try? await deletePermanently(recordingID: recording.id)) != nil else { continue }
      purged.append(recording.id)
    }
    return purged
  }

  /// Names the recording after its summary. Metadata keeps the two values with the recording
  /// so lists can show them without reading every summary file.
  func saveSummaryDetails(_ summary: RecordingSummary, recordingID: String) async throws {
    var values: [String: String] = [:]
    let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { values[RecordingRecord.automaticTitleMetadataKey] = title }
    let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overview.isEmpty { values[RecordingRecord.overviewMetadataKey] = overview }
    guard !values.isEmpty else { return }
    try await store.updateRecordingMetadata(recordingID: recordingID, values: values)
  }

  /// Applies `saveSummaryDetails` to summaries written before recordings kept these details.
  func backfillSummaryDetails(pageSize: Int = 100) async throws {
    let decoder = JSONDecoder()
    for recording in try await allRecordings(pageSize: pageSize)
    where recording.automaticTitle == nil && recording.overview == nil {
      let summaryURL =
        layout.root
        .appending(path: "recordings", directoryHint: .isDirectory)
        .appending(path: recording.id, directoryHint: .isDirectory)
        .appending(path: "summary.json")
      guard let data = try? Data(contentsOf: summaryURL),
        let summary = try? decoder.decode(RecordingSummary.self, from: data)
      else { continue }
      try await saveSummaryDetails(summary, recordingID: recording.id)
    }
  }

  /// Searches every locally indexed recording and local transcript file. It never downloads audio
  /// or remote transcript data as a side effect of searching.
  func search(_ query: String, pageSize: Int = 100) async throws -> RecordingLibrarySearchResult {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return RecordingLibrarySearchResult(
        recordings: try await allRecordings(pageSize: pageSize),
        transcriptFilesSearched: 0,
        recordingsWithoutLocalTranscript: 0,
        transcriptErrors: []
      )
    }

    let recordings = try await allRecordings(pageSize: pageSize)
    var matches: [RecordingRecord] = []
    var searchedCount = 0
    var missingCount = 0
    var errors: [String] = []
    let decoder = JSONDecoder()

    for recording in recordings {
      try Task.checkCancellation()
      if recording.resolvedTitle?.localizedCaseInsensitiveContains(normalized) == true {
        matches.append(recording)
        continue
      }

      let transcriptURL =
        layout.root
        .appending(path: "recordings", directoryHint: .isDirectory)
        .appending(path: recording.id, directoryHint: .isDirectory)
        .appending(path: "transcript.json")
      guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
        missingCount += 1
        continue
      }
      do {
        let segments = try decoder.decode(
          [RealtimeTranscriptEvent].self, from: Data(contentsOf: transcriptURL))
        searchedCount += 1
        if segments.contains(where: { $0.text.localizedCaseInsensitiveContains(normalized) }) {
          matches.append(recording)
        }
      } catch {
        errors.append(recording.id)
      }
    }

    return RecordingLibrarySearchResult(
      recordings: matches,
      transcriptFilesSearched: searchedCount,
      recordingsWithoutLocalTranscript: missingCount,
      transcriptErrors: errors
    )
  }

  /// Local transcripts and summaries for answering questions. Like `search`, it never
  /// downloads anything; recordings without a local transcript are skipped.
  func questionSources(pageSize: Int = 100) async throws -> [RecordingQuestionSource] {
    let decoder = JSONDecoder()
    var sources: [RecordingQuestionSource] = []
    for recording in try await allRecordings(pageSize: pageSize) {
      try Task.checkCancellation()
      let folder =
        layout.root
        .appending(path: "recordings", directoryHint: .isDirectory)
        .appending(path: recording.id, directoryHint: .isDirectory)
      guard
        let data = try? Data(contentsOf: folder.appending(path: "transcript.json")),
        let transcript = try? decoder.decode([RealtimeTranscriptEvent].self, from: data)
      else { continue }
      let summary = (try? Data(contentsOf: folder.appending(path: "summary.json")))
        .flatMap { try? decoder.decode(RecordingSummary.self, from: $0) }
      sources.append(
        RecordingQuestionSource(recording: recording, transcript: transcript, summary: summary))
    }
    return sources
  }

  private func allRecordings(pageSize: Int) async throws -> [RecordingRecord] {
    let safePageSize = max(1, pageSize)
    var result: [RecordingRecord] = []
    while true {
      try Task.checkCancellation()
      let page = try await store.recordings(limit: safePageSize, offset: result.count)
      result.append(contentsOf: page)
      if page.count < safePageSize { return result }
    }
  }
}
