import Foundation
import Testing
@testable import WakeOnCueCore

@Test func recordingPaginationReachesItemsBeyondTwenty() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)

  for index in 1...25 {
    let recording = RecordingRecord(
      id: String(format: "recording-%02d", index),
      createdAt: anchor.addingTimeInterval(Double(index)),
      startedAt: anchor.addingTimeInterval(Double(index)),
      status: .completed,
      localAudioPath: root.appending(path: "\(index).m4a").path,
      uploadStatus: .completed,
      deviceModel: "test",
      appVersion: "1"
    )
    try await store.createRecording(
      recording, createPayloadPath: "", enqueueUpload: false, now: anchor)
  }

  let firstPage = try await store.recordings(limit: 20)
  let secondPage = try await store.recordings(limit: 20, offset: firstPage.count)
  #expect(try await store.recordingCount() == 25)
  #expect(firstPage.count == 20)
  #expect(secondPage.map(\.id) == ["recording-05", "recording-04", "recording-03", "recording-02", "recording-01"])
}

@Test func titlePersistsAcrossReopenedStoreAndSearchesBeyondTwenty() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let databaseURL = root.appending(path: "recordings.sqlite")
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)

  do {
    let store = try RecordingStore(databaseURL: databaseURL)
    for index in 1...25 {
      let recording = RecordingRecord(
        id: String(format: "recording-%02d", index),
        createdAt: anchor.addingTimeInterval(Double(index)),
        startedAt: anchor.addingTimeInterval(Double(index)),
        status: .completed,
        localAudioPath: root.appending(path: "\(index).m4a").path,
        uploadStatus: .completed,
        deviceModel: "test",
        appVersion: "1"
      )
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
    }
    let updated = try await store.updateRecordingTitle(
      recordingID: "recording-01", title: "  Orchid Retrospective  ")
    #expect(updated.title == "Orchid Retrospective")
  }

  let reopened = try RecordingStore(databaseURL: databaseURL)
  #expect(try await reopened.recording(id: "recording-01").title == "Orchid Retrospective")
  #expect(try await reopened.recordings(matchingTitle: "orchid").map(\.id) == ["recording-01"])
}

@Test func metadataUpdatesMergeWithExistingValues() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let recording = RecordingRecord(
    id: "recording-meeting",
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    startedAt: Date(timeIntervalSince1970: 1_800_000_000),
    status: .recording,
    localAudioPath: root.appending(path: "meeting.m4a").path,
    deviceModel: "test",
    appVersion: "1",
    metadata: ["storage_mode": "local"]
  )
  try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
  let updated = try await store.updateRecordingMetadata(
    recordingID: recording.id,
    values: ["title": "Design review", "calendar_event_id": "evt-1"]
  )
  #expect(updated.title == "Design review")
  #expect(updated.metadata["calendar_event_id"] == "evt-1")
  #expect(updated.metadata["storage_mode"] == "local")
}

private func makeLibraryRecording(
  id: String, status: RecordingStatus = .completed, at date: Date, in root: URL
) -> RecordingRecord {
  RecordingRecord(
    id: id,
    createdAt: date,
    startedAt: date,
    status: status,
    localAudioPath: root.appending(path: "\(id).m4a").path,
    uploadStatus: .completed,
    deviceModel: "test",
    appVersion: "1"
  )
}

@Test func deletedRecordingLeavesLibraryAndCanBeRestored() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  for id in ["kept", "deleted"] {
    try await store.createRecording(
      makeLibraryRecording(id: id, at: anchor, in: root),
      createPayloadPath: "", enqueueUpload: false, now: anchor)
  }
  _ = try await store.updateRecordingTitle(recordingID: "deleted", title: "Budget review")

  let deleted = try await store.moveRecordingToTrash(recordingID: "deleted", now: anchor)
  #expect(deleted.deletedAt == anchor)
  #expect(deleted.title == "Budget review")
  #expect(try await store.recordings().map(\.id) == ["kept"])
  #expect(try await store.recordingCount() == 1)
  #expect(try await store.recordings(matchingTitle: "Budget").isEmpty)
  #expect(try await store.deletedRecordings().map(\.id) == ["deleted"])

  let restored = try await store.restoreRecording(recordingID: "deleted")
  #expect(restored.deletedAt == nil)
  #expect(restored.title == "Budget review")
  #expect(try await store.recordingCount() == 2)
  #expect(try await store.deletedRecordings().isEmpty)
}

@Test func recordingStillBeingCapturedCannotBeDeleted() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "active", status: .recording, at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  await #expect(throws: RecordingStoreError.self) {
    try await store.moveRecordingToTrash(recordingID: "active")
  }
  #expect(try await store.activeRecording()?.id == "active")
}

@Test func onlyRecordingsInRecentlyDeletedCanBeRemoved() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  await #expect(throws: RecordingStoreError.self) {
    try await store.removeDeletedRecording(recordingID: "recording")
  }
  #expect(try await store.recordingCount() == 1)

  #expect(try await store.wasPermanentlyDeleted(recordingID: "recording") == false)
  try await store.moveRecordingToTrash(recordingID: "recording")
  #expect(try await store.wasPermanentlyDeleted(recordingID: "recording") == false)
  try await store.removeDeletedRecording(recordingID: "recording")
  #expect(try await store.wasPermanentlyDeleted(recordingID: "recording"))
  #expect(try await store.deletedRecordings().isEmpty)
  await #expect(throws: RecordingStoreError.self) {
    try await store.recording(id: "recording")
  }
}

@Test func automaticTitleYieldsToUserTitleAndIsSearchable() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  let named = try await store.updateRecordingMetadata(
    recordingID: "recording",
    values: [RecordingRecord.automaticTitleMetadataKey: " Launch plan "])
  #expect(named.title == nil)
  #expect(named.resolvedTitle == "Launch plan")
  #expect(try await store.recordings(matchingTitle: "launch").map(\.id) == ["recording"])

  let renamed = try await store.updateRecordingTitle(recordingID: "recording", title: "My title")
  #expect(renamed.resolvedTitle == "My title")

  let cleared = try await store.updateRecordingTitle(recordingID: "recording", title: nil)
  #expect(cleared.resolvedTitle == "Launch plan")
}

@Test func summaryAndTitleWritesFromTwoConnectionsKeepBoth() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let databaseURL = root.appending(path: "recordings.sqlite")
  let summaries = try RecordingStore(databaseURL: databaseURL)
  let titles = try RecordingStore(databaseURL: databaseURL)
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await summaries.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  for round in 0..<300 {
    async let summary = summaries.updateRecordingMetadata(
      recordingID: "recording", values: [RecordingRecord.overviewMetadataKey: "Overview \(round)"])
    async let title = titles.updateRecordingTitle(recordingID: "recording", title: "Title \(round)")
    _ = try await (summary, title)
    let stored = try await summaries.recording(id: "recording")
    #expect(stored.title == "Title \(round)")
    #expect(stored.overview == "Overview \(round)")
  }
}

@Test func deletingAgainKeepsTheOriginalDate() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  try await store.moveRecordingToTrash(recordingID: "recording", now: anchor)
  let again = try await store.moveRecordingToTrash(
    recordingID: "recording", now: anchor.addingTimeInterval(1_000))

  #expect(again.deletedAt == anchor)
}

@Test(arguments: ["abc", "", "nan", "inf"])
func unreadableDeletionDateStaysInRecentlyDeletedAndCanBeRemoved(value: String) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  let recording = RecordingRecord(
    id: "recording", createdAt: anchor, startedAt: anchor, status: .completed,
    localAudioPath: root.appending(path: "recording.m4a").path, deviceModel: "test",
    appVersion: "test", metadata: [RecordingRecord.deletedAtMetadataKey: value])
  try await store.createRecording(
    recording, createPayloadPath: "", enqueueUpload: false, now: anchor)

  #expect(try await store.recordingCount() == 0)
  let stored = try #require(try await store.deletedRecordings().first)
  #expect(stored.isDeleted)
  #expect(stored.deletedAt == nil)

  try await store.removeDeletedRecording(recordingID: "recording")
  #expect(try await store.deletedRecordings().isEmpty)
  #expect(try await store.permanentlyDeletedRecordingIDs() == ["recording"])
}

@Test func restartingRetentionRepairsAnUnreadableDeletionDate() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  let recording = RecordingRecord(
    id: "recording", createdAt: anchor, startedAt: anchor, status: .completed,
    localAudioPath: root.appending(path: "recording.m4a").path, deviceModel: "test",
    appVersion: "test", metadata: [RecordingRecord.deletedAtMetadataKey: "abc"])
  try await store.createRecording(
    recording, createPayloadPath: "", enqueueUpload: false, now: anchor)

  try await store.restartTrashRetention(recordingID: "recording", now: anchor)

  #expect(try await store.recording(id: "recording").deletedAt == anchor)
}

@Test func metadataUpdatesCannotChangeRecentlyDeleted() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)

  await #expect(throws: RecordingStoreError.self) {
    try await store.updateRecordingMetadata(
      recordingID: "recording", values: [RecordingRecord.deletedAtMetadataKey: "abc"])
  }
  #expect(try await store.recordingCount() == 1)
}

@Test func restoringClearsThePendingPurge() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)
  try await store.moveRecordingToTrash(recordingID: "recording", now: anchor)
  try await store.setTrashExpirySeen(recordingID: "recording", at: anchor)
  #expect(try await store.recording(id: "recording").trashExpirySeenAt == anchor)

  let restored = try await store.restoreRecording(recordingID: "recording")

  #expect(restored.trashExpirySeenAt == nil)
  #expect(!restored.isDeleted)
}

@Test func purgeWritesLeaveARecoveredRecordingAlone() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  try await store.createRecording(
    makeLibraryRecording(id: "recording", at: anchor, in: root),
    createPayloadPath: "", enqueueUpload: false, now: anchor)
  try await store.moveRecordingToTrash(recordingID: "recording", now: anchor)
  try await store.restoreRecording(recordingID: "recording")

  // What a purge still working from its earlier list would do.
  try await store.restartTrashRetention(recordingID: "recording", now: anchor)
  try await store.setTrashExpirySeen(recordingID: "recording", at: anchor)

  let stored = try await store.recording(id: "recording")
  #expect(!stored.isDeleted)
  #expect(stored.trashExpirySeenAt == nil)
}

@Test func deletingAgainAfterRecoveryStartsWithoutAPendingPurge() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  let recording = RecordingRecord(
    id: "recording", createdAt: anchor, startedAt: anchor, status: .completed,
    localAudioPath: root.appending(path: "recording.m4a").path, deviceModel: "test",
    appVersion: "test",
    metadata: [RecordingRecord.trashExpirySeenAtMetadataKey: String(anchor.timeIntervalSince1970)])
  try await store.createRecording(
    recording, createPayloadPath: "", enqueueUpload: false, now: anchor)

  let deleted = try await store.moveRecordingToTrash(recordingID: "recording", now: anchor)

  #expect(deleted.trashExpirySeenAt == nil)
}

@Test func identifierUsedAgainIsNotListedAsPermanentlyDeleted() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let anchor = Date(timeIntervalSince1970: 1_800_000_000)
  let recording = makeLibraryRecording(id: "recording", at: anchor, in: root)
  try await store.createRecording(
    recording, createPayloadPath: "", enqueueUpload: false, now: anchor)
  try await store.moveRecordingToTrash(recordingID: "recording", now: anchor)
  try await store.removeDeletedRecording(recordingID: "recording")
  #expect(try await store.permanentlyDeletedRecordingIDs() == ["recording"])

  try await store.createRecording(
    recording, createPayloadPath: "", enqueueUpload: false, now: anchor)

  #expect(try await store.permanentlyDeletedRecordingIDs().isEmpty)
}
