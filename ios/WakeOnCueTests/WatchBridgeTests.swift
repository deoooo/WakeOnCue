import AVFoundation
import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class WatchBridgeTests: XCTestCase {
  func testRecordingSnapshotKeepsRunningClockWithoutNewMessages() {
    let captured = Date(timeIntervalSince1970: 1_000)
    let snapshot = WatchRecordingSnapshot(
      phase: .recording,
      recordingID: "rec_1",
      elapsed: 60,
      capturedAt: captured,
      todayCompletedDuration: 600
    )

    XCTAssertEqual(snapshot.elapsed(at: captured.addingTimeInterval(15)), 75)
    XCTAssertEqual(snapshot.timerStart, captured.addingTimeInterval(-60))
    XCTAssertEqual(snapshot.todayDuration(at: captured.addingTimeInterval(15)), 675)

    var paused = snapshot
    paused.phase = .paused
    XCTAssertEqual(paused.elapsed(at: captured.addingTimeInterval(15)), 60)
  }

  func testEquivalentSnapshotsSkipRedundantTransfers() {
    let base = WatchRecordingSnapshot(
      phase: .recording, recordingID: "rec_1", elapsed: 10,
      capturedAt: Date(timeIntervalSince1970: 100))
    // Five seconds later the same running recording reports the same start time.
    let later = WatchRecordingSnapshot(
      phase: .recording, recordingID: "rec_1", elapsed: 15,
      capturedAt: Date(timeIntervalSince1970: 105))
    let paused = WatchRecordingSnapshot(
      phase: .paused, recordingID: "rec_1", elapsed: 15,
      capturedAt: Date(timeIntervalSince1970: 105))

    XCTAssertTrue(base.isEquivalent(to: later))
    XCTAssertFalse(base.isEquivalent(to: paused))
  }

  func testRequestsAndRepliesSurviveMessageEncoding() throws {
    let bookmarkID = UUID()
    let requests: [WatchBridgeRequest] = [
      .snapshot, .start, .pause, .resume, .finish, .bookmark,
      .markRecent(seconds: 120),
      .tagBookmark(recordingID: "rec_1", bookmarkID: bookmarkID, tag: .todo),
    ]
    for request in requests {
      let message = try WatchBridgeCoding.message(WatchBridgeKey.request, request)
      XCTAssertEqual(
        WatchBridgeCoding.value(WatchBridgeRequest.self, key: WatchBridgeKey.request, in: message),
        request
      )
    }

    let reply = WatchBridgeReply(
      failure: .failed("boom"),
      snapshot: .init(phase: .idle, capturedAt: Date(timeIntervalSince1970: 5)),
      mark: .init(recordingID: "rec_1", bookmarkID: bookmarkID, savedSeconds: 42)
    )
    let data = try WatchBridgeCoding.encode(reply)
    XCTAssertEqual(try WatchBridgeCoding.decode(WatchBridgeReply.self, from: data), reply)
  }

  @MainActor
  func testRangeBookmarkKeepsTagAndSpanAcrossRename() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watch-bookmark-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RecordingAnnotationsService(rootDirectory: root)

    let bookmark = try service.addBookmark(recordingID: "rec_1", position: 30, duration: 120)
    try service.setBookmarkTag(recordingID: "rec_1", bookmarkID: bookmark.id, tag: .important)
    try service.renameBookmark(recordingID: "rec_1", bookmarkID: bookmark.id, title: "Budget")

    let reopened = try RecordingAnnotationsService(rootDirectory: root).reload(recordingID: "rec_1")
    let stored = try XCTUnwrap(reopened.bookmarks.first)
    XCTAssertEqual(stored.duration, 120)
    XCTAssertEqual(stored.tag, .important)
    XCTAssertEqual(stored.title, "Budget")
    XCTAssertEqual(stored.timeRangeText, "00:30–02:30")
  }

  func testLegacyBookmarkJSONStillDecodes() throws {
    let json = """
      {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","position":12,"createdAt":"2026-01-01T00:00:00Z"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let bookmark = try decoder.decode(RecordingBookmark.self, from: Data(json.utf8))
    XCTAssertNil(bookmark.duration)
    XCTAssertNil(bookmark.tag)
    XCTAssertEqual(bookmark.timeRangeText, "00:12")
  }

  @MainActor
  func testWatchRecordingSegmentsAssembleOnceAllPiecesArrive() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watch-session-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let layout = try RecordingFileLayout(root: root.appending(path: "data"))
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let annotations = RecordingAnnotationsService(fileLayout: layout)
    let importer = WatchRecordingImporter(store: store, fileLayout: layout, annotations: annotations)

    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 10_000)
    func stageSegment(_ index: Int, seconds: Double) throws {
      let url = root.appending(path: "incoming-\(index).m4a")
      try Self.writeTone(to: url, seconds: seconds)
      try WatchSessionInbox.stage(
        segmentURL: url,
        metadata: WatchSegmentMetadata(
          sessionID: sessionID, index: index, startedAt: startedAt, duration: seconds),
        root: inbox
      )
    }

    // Segment 2 arrives first; nothing is assembled without the summary.
    try stageSegment(2, seconds: 1)
    var imported = await importer.importPendingSessions(root: inbox)
    XCTAssertEqual(imported, [])

    let summary = WatchSessionSummary(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(3),
      segmentCount: 2,
      bookmarks: [WatchSessionBookmark(position: 1, duration: 1.5, tag: .important)]
    )
    try WatchSessionInbox.stage(summary: summary, root: inbox)
    imported = await importer.importPendingSessions(root: inbox)
    XCTAssertEqual(imported, [], "Segment 1 is still missing")

    try stageSegment(1, seconds: 2)
    imported = await importer.importPendingSessions(root: inbox)
    XCTAssertEqual(imported, [summary.recordingID])

    let recording = try await store.recording(id: summary.recordingID)
    XCTAssertEqual(recording.status, .completed)
    XCTAssertEqual(recording.duration, 3, accuracy: 0.3)
    XCTAssertEqual(recording.startedAt, startedAt)
    XCTAssertEqual(recording.endedAt, summary.endedAt)
    XCTAssertEqual(recording.metadata[WatchRecordingImporter.sourceMetadataKey], "apple_watch")
    let chunks = try await store.chunks(recordingID: summary.recordingID)
    XCTAssertEqual(chunks.map(\.index), [1, 2])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try layout.downloadedAudioURL(recordingID: summary.recordingID).path))
    let bookmark = try XCTUnwrap(annotations.annotations(for: summary.recordingID).bookmarks.first)
    XCTAssertEqual(bookmark.tag, .important)
    XCTAssertEqual(bookmark.position, 1)
    XCTAssertTrue(try WatchSessionInbox.readyItems(root: inbox).isEmpty)

    // A re-sent summary and segment after import do not create a duplicate.
    try stageSegment(1, seconds: 2)
    try stageSegment(2, seconds: 1)
    try WatchSessionInbox.stage(summary: summary, root: inbox)
    _ = await importer.importPendingSessions(root: inbox)
    let count = try await store.recordingCount()
    XCTAssertEqual(count, 1)
  }

  @MainActor
  func testRedeliveredWatchRecordingStaysDeleted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watch-deleted-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let layout = try RecordingFileLayout(root: root.appending(path: "data"))
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let importer = WatchRecordingImporter(
      store: store, fileLayout: layout, annotations: RecordingAnnotationsService(fileLayout: layout))
    let service = RecordingLibraryService(layout: layout, store: store)

    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 10_000)
    let summary = WatchSessionSummary(
      sessionID: sessionID, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1),
      segmentCount: 1)
    func deliverSession() throws {
      let audio = root.appending(path: "delivered-\(UUID()).m4a")
      let file = try AVAudioFile(
        forWriting: audio,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
      buffer.frameLength = 24_000
      try file.write(from: buffer)
      try WatchSessionInbox.stage(
        segmentURL: audio,
        metadata: WatchSegmentMetadata(
          sessionID: sessionID, index: 1, startedAt: startedAt, duration: 1),
        root: inbox)
      try WatchSessionInbox.stage(summary: summary, root: inbox)
    }

    try deliverSession()
    let imported = await importer.importPendingSessions(root: inbox)
    XCTAssertEqual(imported, [summary.recordingID])

    // While it can still be recovered, a redelivery leaves the deleted recording as it is.
    try await service.moveToTrash(recordingID: summary.recordingID)
    try deliverSession()
    _ = await importer.importPendingSessions(root: inbox)
    let inTrash = try await store.deletedRecordings().map(\.id)
    XCTAssertEqual(inTrash, [summary.recordingID])

    try await service.deletePermanently(recordingID: summary.recordingID)
    try deliverSession()
    let reimported = await importer.importPendingSessions(root: inbox)

    XCTAssertTrue(reimported.isEmpty)
    let count = try await store.recordingCount()
    XCTAssertEqual(count, 0)
    let deleted = try await store.deletedRecordings()
    XCTAssertTrue(deleted.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: layout.root.appending(path: "recordings/\(summary.recordingID)").path),
      "Redelivery must not bring back the deleted recording's files")
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty,
      "The redelivered session is cleared from the inbox")
  }

  func testAssemblerReplacesAnEmptyOutputLeftByAnInterruptedExport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "assembler-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try RecordingFileLayout(root: root)
    let recordingID = "rec_assembler"
    let chunkURL = try layout.chunkURL(recordingID: recordingID, index: 1)
    try Self.writeTone(to: chunkURL, seconds: 1.5)
    let chunk = ChunkRecord(
      id: "chunk-1", recordingID: recordingID, index: 1, localPath: chunkURL.path,
      checksum: "", size: 0, startedAt: Date(), duration: 1.5)

    // What an export cut short by app suspension used to leave behind.
    let outputURL = try layout.downloadedAudioURL(recordingID: recordingID)
    FileManager.default.createFile(atPath: outputURL.path, contents: Data())

    let assembled = try await RecordingAudioAssembler(fileLayout: layout).assemble(
      recordingID: recordingID, chunks: [chunk])
    let duration = try await AVURLAsset(url: assembled).load(.duration).seconds
    XCTAssertEqual(duration, 1.5, accuracy: 0.2)
    let partial = outputURL.deletingPathExtension().appendingPathExtension("partial.m4a")
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
  }

  func testSessionSummarySurvivesUserInfoEncoding() throws {
    let summary = WatchSessionSummary(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 61),
      segmentCount: 1,
      bookmarks: [WatchSessionBookmark(position: 3, tag: .todo)],
      endReason: "interruption"
    )
    let info = try WatchBridgeCoding.message(WatchBridgeKey.session, summary)
    XCTAssertEqual(
      WatchBridgeCoding.value(WatchSessionSummary.self, key: WatchBridgeKey.session, in: info),
      summary)
    XCTAssertTrue(summary.recordingID.hasPrefix("rec_watchrec_"))
  }

  private static func writeTone(to url: URL, seconds: Double) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
      ],
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
      buffer.int16ChannelData![0][index] = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000))
    }
    try file.write(from: buffer)
  }
}
