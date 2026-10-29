import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class RecordingLibrarySearchTests: XCTestCase {
  func testSearchFindsTranscriptBeyondFirstTwentyAndReportsUnreadableFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-search-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try RecordingFileLayout(root: root)
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let anchor = Date()
    for index in 0..<25 {
      let id = "search-\(index)"
      let date = anchor.addingTimeInterval(-Double(index))
      let recording = RecordingRecord(
        id: id, createdAt: date, startedAt: date, status: .recording,
        localAudioPath: try layout.sourceAudioURL(recordingID: id).path,
        deviceModel: "test", appVersion: "test"
      )
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
      try await store.completeLocally(recordingID: id, duration: 2)
    }
    let target = RealtimeTranscriptEvent(
      recordingID: "search-24", segmentID: "oldest-text", revision: 1,
      startMilliseconds: 0, endMilliseconds: 2_000,
      text: "Orchid launch review", isFinal: true, speaker: nil
    )
    try JSONEncoder().encode([target]).write(to: layout.transcriptURL(recordingID: "search-24"))
    try Data("invalid json".utf8).write(to: layout.transcriptURL(recordingID: "search-23"))

    let service = try RecordingLibraryService(layout: layout)
    let result = try await service.search("oRCHid", pageSize: 7)
    XCTAssertEqual(result.recordings.map(\.id), ["search-24"])
    XCTAssertEqual(result.transcriptFilesSearched, 1)
    XCTAssertEqual(result.recordingsWithoutLocalTranscript, 23)
    XCTAssertEqual(result.transcriptErrors, ["search-23"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: try layout.downloadedAudioURL(recordingID: "search-0").path))
  }

  func testCancelledSearchDoesNotReturnStaleResults() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try RecordingLibraryService(layout: RecordingFileLayout(root: root))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.search("Orchid")
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled search should throw rather than publish results")
    } catch is CancellationError {}
  }
}
