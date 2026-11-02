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

  private func makeLibrary(
    ids: [String]
  ) async throws -> (RecordingFileLayout, RecordingStore, RecordingLibraryService) {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let layout = try RecordingFileLayout(root: root)
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    for id in ids {
      let recording = RecordingRecord(
        id: id, createdAt: Date(), startedAt: Date(), status: .recording,
        localAudioPath: try layout.sourceAudioURL(recordingID: id).path,
        deviceModel: "test", appVersion: "test"
      )
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
      try await store.completeLocally(recordingID: id, duration: 2)
    }
    return (layout, store, RecordingLibraryService(layout: layout, store: store))
  }

  private func writeTranscript(_ text: String, id: String, layout: RecordingFileLayout) throws {
    let segment = RealtimeTranscriptEvent(
      recordingID: id, segmentID: "\(id)-1", revision: 1,
      startMilliseconds: 0, endMilliseconds: 2_000,
      text: text, isFinal: true, speaker: nil
    )
    try JSONEncoder().encode([segment]).write(to: layout.transcriptURL(recordingID: id))
  }

  func testDeletedRecordingLeavesSearchAndQuestionsUntilRestored() async throws {
    let (layout, _, service) = try await makeLibrary(ids: ["target"])
    try writeTranscript("Orchid launch review", id: "target", layout: layout)

    try await service.moveToTrash(recordingID: "target")
    let hidden = try await service.search("Orchid")
    XCTAssertTrue(hidden.recordings.isEmpty)
    let hiddenSources = try await service.questionSources()
    XCTAssertTrue(hiddenSources.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: try layout.transcriptURL(recordingID: "target").path),
      "Moving to Recently Deleted keeps the files so the recording can be recovered")

    try await service.restore(recordingID: "target")
    let found = try await service.search("Orchid")
    XCTAssertEqual(found.recordings.map(\.id), ["target"])
  }

  func testPermanentDeletionRemovesFilesAndRefusesLibraryRecordings() async throws {
    let (layout, store, service) = try await makeLibrary(ids: ["target", "other"])
    try writeTranscript("Kept", id: "other", layout: layout)
    let targetAudio = try layout.sourceAudioURL(recordingID: "target")
    try Data("audio".utf8).write(to: targetAudio)

    do {
      try await service.deletePermanently(recordingID: "target")
      XCTFail("A recording in the library must not be deleted permanently")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetAudio.path))

    try await service.moveToTrash(recordingID: "target")
    try await service.deletePermanently(recordingID: "target")
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetAudio.deletingLastPathComponent().path))
    let remaining = try await store.recordings().map(\.id)
    XCTAssertEqual(remaining, ["other"])
    let deleted = try await store.deletedRecordings()
    XCTAssertTrue(deleted.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: try layout.transcriptURL(recordingID: "other").path))
  }

  func testPurgeDeletesOnlyRecordingsPastRetention() async throws {
    let (layout, store, service) = try await makeLibrary(ids: ["expired", "recent", "kept"])
    let now = Date()
    try await store.moveRecordingToTrash(
      recordingID: "expired", now: now.addingTimeInterval(-RecordingStore.trashRetention - 1))
    try await store.moveRecordingToTrash(
      recordingID: "recent", now: now.addingTimeInterval(-RecordingStore.trashRetention + 60))

    try await service.purgeExpiredRecordings(now: now)
    let waiting = try await store.deletedRecordings().map(\.id)
    XCTAssertEqual(
      Set(waiting), ["expired", "recent"], "The first run after the period only notes the expiry")
    try await service.purgeExpiredRecordings(
      now: now.addingTimeInterval(RecordingStore.trashPurgeConfirmationDelay - 60))
    let tooSoon = try await store.deletedRecordings().map(\.id)
    XCTAssertTrue(tooSoon.contains("expired"))

    let purged = try await service.purgeExpiredRecordings(
      now: now.addingTimeInterval(RecordingStore.trashPurgeConfirmationDelay + 1))

    XCTAssertEqual(purged, ["expired"])
    let deleted = try await store.deletedRecordings().map(\.id)
    XCTAssertEqual(deleted, ["recent"])
    let library = try await store.recordings().map(\.id)
    XCTAssertEqual(library, ["kept"])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: layout.root.appending(path: "recordings/expired").path))
  }

  func testDateMovedForwardAndBackDeletesNothing() async throws {
    let (_, store, service) = try await makeLibrary(ids: ["target"])
    let now = Date()
    try await store.moveRecordingToTrash(recordingID: "target", now: now)
    let ahead = now.addingTimeInterval(RecordingStore.trashRetention + 60)

    try await service.purgeExpiredRecordings(now: ahead)
    try await service.purgeExpiredRecordings(now: now)
    try await service.purgeExpiredRecordings(
      now: ahead.addingTimeInterval(RecordingStore.trashPurgeConfirmationDelay))

    let deleted = try await store.deletedRecordings().map(\.id)
    XCTAssertEqual(deleted, ["target"], "Returning to the right date restarts the confirmation")
  }

  func testPurgeRestartsAFutureDeletionDate() async throws {
    let (_, store, service) = try await makeLibrary(ids: ["target"])
    let now = Date()
    try await store.moveRecordingToTrash(
      recordingID: "target", now: now.addingTimeInterval(RecordingStore.trashRetention * 3))

    try await service.purgeExpiredRecordings(now: now)

    let stored = try await store.recording(id: "target")
    XCTAssertEqual(
      stored.deletedAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
  }

  func testPermanentDeletionRefusesARestoredRecordingAndCannotBeRecovered() async throws {
    let (layout, store, service) = try await makeLibrary(ids: ["target"])
    let audio = try layout.sourceAudioURL(recordingID: "target")
    try Data("audio".utf8).write(to: audio)
    try await service.moveToTrash(recordingID: "target")
    try await service.restore(recordingID: "target")

    do {
      try await service.deletePermanently(recordingID: "target")
      XCTFail("A recording that was recovered must keep its files")
    } catch RecordingStoreError.notInRecentlyDeleted {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))

    try await service.moveToTrash(recordingID: "target")
    try await service.deletePermanently(recordingID: "target")
    do {
      try await service.restore(recordingID: "target")
      XCTFail("A permanently deleted recording cannot be recovered")
    } catch RecordingStoreError.notFound {}
    let wasDeleted = try await store.wasPermanentlyDeleted(recordingID: "target")
    XCTAssertTrue(wasDeleted)
  }

  func testUpkeepRemovesFoldersOfDeletedRecordingsOnly() async throws {
    let (layout, _, service) = try await makeLibrary(ids: ["target", "other"])
    let otherAudio = try layout.sourceAudioURL(recordingID: "other")
    try Data("audio".utf8).write(to: otherAudio)
    try await service.moveToTrash(recordingID: "target")
    try await service.deletePermanently(recordingID: "target")
    let recreated = try layout.directory(for: "target")
    XCTAssertTrue(FileManager.default.fileExists(atPath: recreated.path))

    try await service.removeFilesOfDeletedRecordings()

    XCTAssertFalse(FileManager.default.fileExists(atPath: recreated.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: otherAudio.path))
  }

  func testUpkeepKeepsFilesOfARecordingUsingADeletedIdentifierAgain() async throws {
    let (layout, store, service) = try await makeLibrary(ids: ["target"])
    try await service.moveToTrash(recordingID: "target")
    try await service.deletePermanently(recordingID: "target")
    let audio = try layout.sourceAudioURL(recordingID: "target")
    try Data("audio".utf8).write(to: audio)
    try await store.createRecording(
      RecordingRecord(
        id: "target", createdAt: Date(), startedAt: Date(), status: .recording,
        localAudioPath: audio.path, deviceModel: "test", appVersion: "test"),
      createPayloadPath: "", enqueueUpload: false)

    try await service.removeFilesOfDeletedRecordings()

    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
  }

  func testPermanentDeletionRemovesTranscriptExports() async throws {
    let id = "export-\(UUID())"
    let (layout, _, service) = try await makeLibrary(ids: [id])
    let recording = try await service.recording(id: id)
    let item = try RecordingTranscriptExporter.write(
      recording: recording, transcript: [], speakerAliases: [:], format: .plainText,
      directory: RecordingFileLayout.transcriptExportDirectory(recordingID: id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    _ = layout

    try await service.moveToTrash(recordingID: id)
    try await service.deletePermanently(recordingID: id)

    XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
  }

  @MainActor
  func testTagForAGoneBookmarkDoesNotBringTheFolderBack() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "annotations-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RecordingAnnotationsService(rootDirectory: root)

    try service.setBookmarkTag(recordingID: "gone", bookmarkID: UUID(), tag: nil)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appending(path: "recordings/gone/annotations.json").path))
  }

  func testSavingAnUnchangedAutomaticTitleIsNotAnEdit() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let recording = RecordingRecord(
      id: "recording", createdAt: date, startedAt: date, status: .completed,
      localAudioPath: "/tmp/recording.m4a", deviceModel: "test", appVersion: "test",
      metadata: [RecordingRecord.automaticTitleMetadataKey: "Launch plan"]
    )
    XCTAssertFalse(recording.isTitleChange("Launch plan"))
    XCTAssertFalse(recording.isTitleChange("  Launch plan\n"))
    XCTAssertTrue(recording.isTitleChange("Launch plan v2"))
    XCTAssertTrue(recording.isTitleChange(""), "Clearing a user title falls back to the summary's")
  }

  func testRemainingDaysStayInRangeForDatesOutOfRange() {
    func days(deletedAt value: String) -> Int {
      let date = Date(timeIntervalSince1970: 1_800_000_000)
      return RecordingRecord(
        id: "recording", createdAt: date, startedAt: date, status: .completed,
        localAudioPath: "/tmp/recording.m4a", deviceModel: "test", appVersion: "test",
        metadata: [RecordingRecord.deletedAtMetadataKey: value]
      ).daysUntilPermanentDeletion(now: date)
    }
    XCTAssertEqual(days(deletedAt: "nan"), 30)
    XCTAssertEqual(days(deletedAt: "abc"), 30)
    XCTAssertEqual(days(deletedAt: "1e300"), 30)
    XCTAssertEqual(days(deletedAt: "-1e300"), 0)
  }

  func testRemainingDaysCountPartialDaysAndStopAtZero() throws {
    let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let recording = RecordingRecord(
      id: "recording", createdAt: deletedAt, startedAt: deletedAt, status: .completed,
      localAudioPath: "/tmp/recording.m4a", deviceModel: "test", appVersion: "test",
      metadata: [RecordingRecord.deletedAtMetadataKey: String(deletedAt.timeIntervalSince1970)]
    )
    XCTAssertEqual(recording.daysUntilPermanentDeletion(now: deletedAt), 30)
    XCTAssertEqual(
      recording.daysUntilPermanentDeletion(now: deletedAt.addingTimeInterval(60)), 30)
    XCTAssertEqual(
      recording.daysUntilPermanentDeletion(
        now: deletedAt.addingTimeInterval(RecordingStore.trashRetention - 60)), 1)
    XCTAssertEqual(
      recording.daysUntilPermanentDeletion(
        now: deletedAt.addingTimeInterval(RecordingStore.trashRetention + 60)), 0)
  }

  func testSummaryNamesRecordingWithoutReplacingAUserOrCalendarTitle() async throws {
    let (layout, store, service) = try await makeLibrary(ids: ["untitled", "titled", "blank"])
    try await store.updateRecordingTitle(recordingID: "titled", title: "Weekly sync")
    let summary = RecordingSummary(
      title: " Launch plan ", overview: "Agreed the launch date.", keyPoints: [],
      actionItems: [], generatedAt: Date())
    for id in ["untitled", "titled"] {
      try JSONEncoder().encode(summary).write(to: layout.summaryURL(recordingID: id))
    }
    let blank = RecordingSummary(
      title: "  ", overview: "", keyPoints: [], actionItems: [], generatedAt: Date())
    try JSONEncoder().encode(blank).write(to: layout.summaryURL(recordingID: "blank"))

    try await service.backfillSummaryDetails()

    let untitled = try await store.recording(id: "untitled")
    XCTAssertEqual(untitled.resolvedTitle, "Launch plan")
    XCTAssertEqual(untitled.overview, "Agreed the launch date.")
    let titled = try await store.recording(id: "titled")
    XCTAssertEqual(titled.resolvedTitle, "Weekly sync")
    let blankRecording = try await store.recording(id: "blank")
    XCTAssertNil(blankRecording.resolvedTitle)
    let found = try await service.search("launch plan")
    XCTAssertEqual(found.recordings.map(\.id).sorted(), ["untitled"])
  }
}
