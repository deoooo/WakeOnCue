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
      if recording.title?.localizedCaseInsensitiveContains(normalized) == true {
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
