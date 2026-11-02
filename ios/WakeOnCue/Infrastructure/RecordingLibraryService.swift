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

  init(layout: RecordingFileLayout) throws {
    self.layout = layout
    store = try RecordingStore(databaseURL: layout.databaseURL)
  }

  init(layout: RecordingFileLayout, store: RecordingStore) {
    self.layout = layout
    self.store = store
  }

  func page(limit: Int, offset: Int) async throws -> [RecordingRecord] {
    try await store.recordings(limit: limit, offset: offset)
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

  /// Files go first so a failure leaves the recording in Recently Deleted to retry, rather
  /// than leaving audio on the iPhone that nothing in the app can reach.
  func deletePermanently(recordingID: String) async throws {
    guard try await store.recording(id: recordingID).deletedAt != nil else {
      throw RecordingStoreError.invalidData("Recording is not in Recently Deleted")
    }
    try layout.removeFiles(recordingID: recordingID)
    try await store.removeDeletedRecording(recordingID: recordingID)
  }

  /// Permanently deletes recordings past the retention period. One that fails is retried
  /// the next time this runs.
  func purgeExpiredRecordings(now: Date = Date()) async throws {
    for recording in try await store.deletedRecordings() {
      guard let deletedAt = recording.deletedAt,
        now.timeIntervalSince(deletedAt) >= RecordingStore.trashRetention
      else { continue }
      try? await deletePermanently(recordingID: recording.id)
    }
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
