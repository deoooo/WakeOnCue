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
