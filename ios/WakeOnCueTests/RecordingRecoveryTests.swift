import AVFoundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class RecordingRecoveryTests: XCTestCase {
  private var directory: URL!
  private var store: RecordingStore!
  private var layout: RecordingFileLayout!
  private var createdIDs: [String] = []

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try RecordingStore(databaseURL: directory.appending(path: "recordings.sqlite"))
    layout = try RecordingFileLayout()
  }

  override func tearDown() async throws {
    for id in createdIDs { try? FileManager.default.removeItem(at: layout.directory(for: id)) }
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeRecording(
    _ suffix: String, status: RecordingStatus = .recording, audioPath: String? = nil
  ) async throws -> String {
    let id = "recovery_\(suffix)_\(UUID().uuidString.prefix(8))"
    createdIDs.append(id)
    try await store.createRecording(
      RecordingRecord(
        id: id, createdAt: .now, startedAt: .now, status: .recording,
        localAudioPath: audioPath ?? directory.appending(path: "\(id).caf").path,
        deviceModel: "test", appVersion: "1"),
      createPayloadPath: "",
      enqueueUpload: false
    )
    if status != .recording {
      try await store.transition(recordingID: id, to: .finishing, duration: 3)
    }
    if status == .failed || status == .uploading {
      try await store.transition(recordingID: id, to: .uploading, duration: 3)
    }
    if status == .failed {
      try await store.transition(recordingID: id, to: .failed, duration: 3)
    }
    return id
  }

  private func writeAudio(to url: URL, seconds: Double = 1) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let file = try AVAudioFile(
      forWriting: url,
      settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1])
    let frames = AVAudioFrameCount(seconds * 24_000)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    try file.write(from: buffer)
  }

  private var noPreparation: @Sendable (String) async -> Void { { _ in } }

  func testDamagedChunkDoesNotHoldBackTheOtherRecordings() async throws {
    let damaged = try await makeRecording("damaged")
    let healthy = try await makeRecording("healthy")
    try Data("not audio".utf8).write(to: layout.chunkURL(recordingID: damaged, index: 1))
    try writeAudio(to: layout.chunkURL(recordingID: damaged, index: 2))
    try writeAudio(to: layout.chunkURL(recordingID: healthy, index: 1))

    let interrupted = try await store.recoverAfterProcessTermination()
    XCTAssertEqual(Set(interrupted), [damaged, healthy])
    let outcome = await RecordingRecoveryService(fileLayout: layout).finishInterrupted(
      interrupted, store: store, prepareAudio: noPreparation)

    XCTAssertNil(outcome.firstError)
    XCTAssertEqual(Set(outcome.finished.map(\.id)), [damaged, healthy])
    let damagedStatus = try await store.recording(id: damaged).status
    let damagedChunks = try await store.chunks(recordingID: damaged)
    let healthyChunks = try await store.chunks(recordingID: healthy)
    XCTAssertEqual(damagedStatus, .completed)
    XCTAssertEqual(damagedChunks.map(\.index), [2], "The readable chunk is kept")
    XCTAssertEqual(healthyChunks.map(\.index), [1])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try layout.chunkURL(recordingID: damaged, index: 1).path),
      "Recovery does not delete what it cannot read")
  }

  func testImportStrandedWithChunkZeroIsRecovered() async throws {
    let id = try await makeRecording("import", status: .finishing)
    try writeAudio(to: layout.chunkURL(recordingID: id, index: 0))

    let outcome = await RecordingRecoveryService(fileLayout: layout).finishInterrupted(
      [id], store: store, prepareAudio: noPreparation)

    XCTAssertNil(outcome.firstError)
    let chunks = try await store.chunks(recordingID: id)
    XCTAssertEqual(chunks.map(\.index), [1])
    XCTAssertTrue(chunks[0].localPath.hasSuffix("000000.m4a"))
    let status = try await store.recording(id: id).status
    XCTAssertEqual(status, .completed)
  }

  func testRetiredUploadsFinishButFailedRecordingsNeedAudio() async throws {
    let uploading = try await makeRecording("uploading", status: .uploading)
    let audio = directory.appending(path: "failed.caf")
    try Data("source".utf8).write(to: audio)
    let failedWithAudio = try await makeRecording("failed", status: .failed, audioPath: audio.path)
    let failedEmpty = try await makeRecording("empty", status: .failed)

    let outcome = await RecordingRecoveryService(fileLayout: layout).finishRetiredUploads(
      store: store, prepareAudio: noPreparation)

    XCTAssertNil(outcome.firstError)
    XCTAssertEqual(Set(outcome.finished.map(\.id)), [uploading, failedWithAudio])
    let emptyStatus = try await store.recording(id: failedEmpty).status
    XCTAssertEqual(emptyStatus, .failed)
    let keptDuration = try await store.recording(id: uploading).duration
    XCTAssertEqual(keptDuration, 3)
  }

  func testFinishedRecordingStuckUploadingSettlesSoItsBackupDownloads() async throws {
    let id = "recovery_settle_\(UUID().uuidString.prefix(8))"
    createdIDs.append(id)
    try await store.createRecording(
      RecordingRecord(
        id: id, createdAt: .now, startedAt: .now, status: .recording,
        localAudioPath: directory.appending(path: "\(id).caf").path,
        deviceModel: "test", appVersion: "1"),
      createPayloadPath: directory.appending(path: "\(id)-create.json").path,
      enqueueUpload: true
    )
    func uploadNext(_ identifier: Int) async throws {
      let eligible = try await store.eligibleUploadTasks()
      let task = try XCTUnwrap(eligible.first { $0.recordingID == id })
      try await store.claimUploadTask(id: task.id, backgroundTaskIdentifier: identifier)
      try await store.markUploadTaskUploaded(id: task.id)
    }
    try await uploadNext(1)
    try await store.transition(recordingID: id, to: .finishing, duration: 1)
    try await store.enqueueControlTask(
      recordingID: id, kind: .finish, payloadPath: directory.appending(path: "\(id).m4a").path)
    try await uploadNext(2)
    let transcript = directory.appending(path: "\(id).json")
    try Data("[]".utf8).write(to: transcript)
    try await store.enqueueTranscriptTask(recordingID: id, transcriptPath: transcript.path)
    let pending = try await store.eligibleUploadTasks()
    let task = try XCTUnwrap(pending.first { $0.recordingID == id })
    try await store.claimUploadTask(id: task.id, backgroundTaskIdentifier: 3)
    let stuck = try await store.recording(id: id)
    XCTAssertEqual(stuck.status, .completed)
    XCTAssertEqual(stuck.uploadStatus, .uploading)

    let outcome = await RecordingRecoveryService(fileLayout: layout).finishRetiredUploads(
      store: store, prepareAudio: noPreparation)

    XCTAssertNil(outcome.firstError)
    let settled = try await store.recording(id: id).uploadStatus
    let backedUp = try await store.isBackedUpToS3(recordingID: id)
    XCTAssertEqual(settled, .completed)
    XCTAssertTrue(backedUp)
  }

  @MainActor
  func testImportedFileBecomesACompletedRecording() async throws {
    let source = directory.appending(path: "Voice memo.m4a")
    try writeAudio(to: source, seconds: 2)

    let recording = try await AudioFileImporter(store: store, fileLayout: layout)
      .importFile(at: source)
    createdIDs.append(recording.id)

    XCTAssertEqual(recording.status, .completed)
    XCTAssertEqual(recording.metadata[RecordingRecord.titleMetadataKey], "Voice memo")
    let chunks = try await store.chunks(recordingID: recording.id)
    XCTAssertEqual(chunks.map(\.index), [1])
    XCTAssertGreaterThan(recording.duration, 1)
  }
}
