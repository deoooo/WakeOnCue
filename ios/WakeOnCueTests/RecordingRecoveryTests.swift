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
  func testUnreadableTranscriptIsNotReplacedByAutomaticTranscription() async throws {
    let id = "recovery_unreadable_\(UUID().uuidString.prefix(8))"
    createdIDs.append(id)
    let unreadable = Data("not a transcript".utf8)
    let transcriptURL = try layout.transcriptURL(recordingID: id)
    try unreadable.write(to: transcriptURL)
    let readError = try XCTUnwrap(
      { () -> Error? in
        do {
          _ = try JSONDecoder().decode([RealtimeTranscriptEvent].self, from: unreadable)
          return nil
        } catch { return error }
      }())
    let model = try AppModel()

    await model.processOnDevice(
      recording: RecordingRecord(
        id: id, createdAt: .now, startedAt: .now, status: .completed,
        localAudioPath: directory.appending(path: "missing.caf").path,
        deviceModel: "test", appVersion: "1"),
      audioURL: directory.appending(path: "missing.m4a")
    )

    XCTAssertEqual(try Data(contentsOf: transcriptURL), unreadable)
    XCTAssertEqual(
      model.errorMessage,
      String(
        format: AppLanguage.localized("Could not process this recording: %@"),
        readError.localizedDescription),
      "Stops on the read failure instead of going on to transcribe")
  }

  /// Records every call to the services a recording could be sent to.
  @MainActor
  private final class ProcessingProbe {
    var transcribeCalls = 0
    var summarizeCalls = 0
    var onTranscribe: () async throws -> Void = {}
    var onSummarize: () async throws -> Void = {}

    func services(recordingID: String) -> RecordingProcessingServices {
      RecordingProcessingServices(
        canTranscribe: { true },
        transcribe: { [self] _, _ in
          transcribeCalls += 1
          try await onTranscribe()
          return [
            RealtimeTranscriptEvent(
              recordingID: recordingID, segmentID: "segment", revision: 1,
              startMilliseconds: 0, endMilliseconds: 1_000,
              text: "Discarded by accident", isFinal: true, speaker: nil)
          ]
        },
        canSummarize: { true },
        summarize: { [self] _, _ in
          summarizeCalls += 1
          try await onSummarize()
          return RecordingSummary(
            title: "Launch plan", overview: "Agreed a date.", keyPoints: [], actionItems: [],
            generatedAt: Date())
        }
      )
    }
  }

  /// A finished recording in the model's own library, removed again when the test ends.
  @MainActor
  private func makeProcessableRecording() async throws -> (RecordingRecord, RecordingFileLayout, RecordingStore) {
    let layout = try RecordingFileLayout()
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let id = "processing-\(UUID().uuidString)"
    let audio = try layout.downloadedAudioURL(recordingID: id)
    try writeAudio(to: audio, seconds: 1)
    try await store.createRecording(
      RecordingRecord(
        id: id, createdAt: .now, startedAt: .now, status: .recording,
        localAudioPath: audio.path, deviceModel: "test", appVersion: "1"),
      createPayloadPath: "", enqueueUpload: false)
    try await store.completeLocally(recordingID: id, duration: 1)
    addTeardownBlock {
      try? await store.moveRecordingToTrash(recordingID: id)
      try? await store.removeDeletedRecording(recordingID: id)
      try? layout.removeFiles(recordingID: id)
    }
    return (try await store.recording(id: id), layout, store)
  }

  @MainActor
  func testDeletingDuringTranscriptionSendsNothingToTheSummaryService() async throws {
    let model = try AppModel()
    let (recording, layout, _) = try await makeProcessableRecording()
    let probe = ProcessingProbe()
    model.processingServices = probe.services(recordingID: recording.id)
    probe.onTranscribe = { _ = await model.moveToTrash(recording) }

    await model.processOnDevice(
      recording: recording, audioURL: try layout.downloadedAudioURL(recordingID: recording.id))

    XCTAssertEqual(probe.transcribeCalls, 1)
    XCTAssertEqual(probe.summarizeCalls, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try layout.transcriptURL(recordingID: recording.id).path))
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(model.onDeviceProcessingRecordingIDs.isEmpty)
  }

  @MainActor
  func testPlayAndShareDoNothingOnceTheRecordingIsDeleted() async throws {
    let model = try AppModel()
    let (recording, _, _) = try await makeProcessableRecording()
    _ = await model.moveToTrash(recording)

    await model.togglePlayback(for: recording)
    await model.share(recording: recording)

    XCTAssertNil(model.playingRecordingID, "A screen left open must not start the audio")
    XCTAssertNil(model.shareItem)
  }

  @MainActor
  func testDeletingARecordingInProgressGivesATranslatedReason() async throws {
    let model = try AppModel()
    let layout = try RecordingFileLayout()
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let id = "rec_in_progress_\(UUID().uuidString)"
    let recording = RecordingRecord(
      id: id, createdAt: Date(), startedAt: Date(), status: .recording,
      localAudioPath: try layout.sourceAudioURL(recordingID: id).path,
      deviceModel: "test", appVersion: "test"
    )
    try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)

    let moved = await model.moveToTrash(recording)

    XCTAssertFalse(moved)
    XCTAssertTrue(
      model.errorMessage?.contains(
        AppLanguage.localized("This recording is still being recorded or finished.")) == true)
    try await store.completeLocally(recordingID: id, duration: 1)
    try await store.moveRecordingToTrash(recordingID: id)
    try await store.removeDeletedRecording(recordingID: id)
    try layout.removeFiles(recordingID: id)
  }

  @MainActor
  func testDeletingCancelsARequestAlreadyInFlight() async throws {
    let model = try AppModel()
    let (recording, layout, _) = try await makeProcessableRecording()
    let probe = ProcessingProbe()
    model.processingServices = probe.services(recordingID: recording.id)
    var requestWasCancelled = false
    let requestStarted = expectation(description: "request started")
    probe.onTranscribe = {
      requestStarted.fulfill()
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        requestWasCancelled = true
        throw URLError(.cancelled)
      }
    }
    let audioURL = try layout.downloadedAudioURL(recordingID: recording.id)
    let processing = Task { await model.processOnDevice(recording: recording, audioURL: audioURL) }
    await fulfillment(of: [requestStarted], timeout: 10)

    let moved = await model.moveToTrash(recording)
    await processing.value

    XCTAssertTrue(moved)
    XCTAssertTrue(requestWasCancelled)
    XCTAssertEqual(probe.summarizeCalls, 0)
    XCTAssertNil(model.errorMessage, "Stopping because of a deletion is not a failure to report")
  }

  @MainActor
  func testDeletedRecordingIsNotSentWhenProcessingStartsLater() async throws {
    let model = try AppModel()
    let (recording, layout, _) = try await makeProcessableRecording()
    let probe = ProcessingProbe()
    model.processingServices = probe.services(recordingID: recording.id)
    _ = await model.moveToTrash(recording)

    await model.processOnDevice(
      recording: recording, audioURL: try layout.downloadedAudioURL(recordingID: recording.id))
    await model.retranscribe(recording: recording)

    XCTAssertEqual(probe.transcribeCalls, 0)
    XCTAssertEqual(probe.summarizeCalls, 0)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testDeletingDuringRetranscriptionKeepsTheExistingTranscript() async throws {
    let model = try AppModel()
    let (recording, layout, _) = try await makeProcessableRecording()
    let transcriptURL = try layout.transcriptURL(recordingID: recording.id)
    let existing = Data("[]".utf8)
    try existing.write(to: transcriptURL)
    let probe = ProcessingProbe()
    model.processingServices = probe.services(recordingID: recording.id)
    probe.onTranscribe = { _ = await model.moveToTrash(recording) }

    await model.retranscribe(recording: recording)

    XCTAssertEqual(probe.transcribeCalls, 1)
    XCTAssertEqual(try Data(contentsOf: transcriptURL), existing)
    XCTAssertNil(model.errorMessage)
    XCTAssertNil(model.retranscribingRecordingID)
  }

  @MainActor
  func testDeletingDuringSummaryWritesNoSummaryAndRecoveredRecordingCanBeProcessedAgain()
    async throws
  {
    let model = try AppModel()
    let (recording, layout, store) = try await makeProcessableRecording()
    let probe = ProcessingProbe()
    model.processingServices = probe.services(recordingID: recording.id)
    probe.onSummarize = { _ = await model.moveToTrash(recording) }
    let audioURL = try layout.downloadedAudioURL(recordingID: recording.id)

    await model.processOnDevice(recording: recording, audioURL: audioURL)

    XCTAssertEqual(probe.summarizeCalls, 1)
    XCTAssertNil(model.summary(for: recording.id))
    let deleted = try await store.recording(id: recording.id)
    XCTAssertNil(deleted.automaticTitle)

    probe.onSummarize = {}
    await model.restore(recording)
    await model.processOnDevice(recording: recording, audioURL: audioURL)

    XCTAssertEqual(probe.summarizeCalls, 2)
    XCTAssertEqual(model.summary(for: recording.id)?.title, "Launch plan")
    let restored = try await store.recording(id: recording.id)
    XCTAssertEqual(restored.resolvedTitle, "Launch plan")
    XCTAssertNil(model.errorMessage)
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
