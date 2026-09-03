import Foundation
import Testing

@testable import WakeOnCueCore

@Test func buildsDirectS3RequestAndStableObjectKeys() throws {
  let configuration = S3Configuration(
    endpointURL: URL(string: "https://storage.example.com"),
    region: "us-east-1",
    bucket: "meeting-audio",
    prefix: "wake on cue",
    accessKeyID: "TESTACCESS",
    secretAccessKey: "test-secret",
    forcePathStyle: true
  )
  let task = UploadTaskRecord(
    id: "task_1",
    recordingID: "rec_123",
    chunkID: "chunk_1",
    kind: .uploadChunk,
    deduplicationKey: "rec_123:chunk:1",
    localFilePath: "/tmp/1.m4a",
    createdAt: .now,
    updatedAt: .now
  )
  let chunk = ChunkRecord(
    id: "chunk_1",
    recordingID: "rec_123",
    index: 1,
    localPath: "/tmp/1.m4a",
    checksum: String(repeating: "a", count: 64),
    size: 3,
    startedAt: .now,
    duration: 10
  )
  let key = configuration.objectKey(for: task, chunk: chunk)
  #expect(key == "wake on cue/recordings/rec_123/chunks/000001.m4a")
  let transcriptTask = UploadTaskRecord(
    id: "task_transcript",
    recordingID: "rec_123",
    kind: .transcript,
    deduplicationKey: "rec_123:transcript",
    localFilePath: "/tmp/transcript.json",
    createdAt: .now,
    updatedAt: .now
  )
  #expect(
    configuration.objectKey(for: transcriptTask, chunk: nil)
      == "wake on cue/recordings/rec_123/transcript.json"
  )

  let request = try S3RequestSigner.signedRequest(
    method: "PUT",
    objectKey: key,
    contentType: "audio/mp4",
    payloadHash: S3RequestSigner.payloadHash(Data("abc".utf8)),
    configuration: configuration,
    date: Date(timeIntervalSince1970: 1_700_000_000)
  )
  #expect(
    request.url?.absoluteString
      == "https://storage.example.com/meeting-audio/wake%20on%20cue/recordings/rec_123/chunks/000001.m4a"
  )
  #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20231114T221320Z")
  #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("TESTACCESS") == true)
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
  #expect(configuration.matchesRecordedLocation(configuration.recordingMetadata))
  let otherBucket = S3Configuration(
    region: configuration.region,
    bucket: "different-bucket",
    prefix: configuration.prefix,
    accessKeyID: configuration.accessKeyID,
    secretAccessKey: configuration.secretAccessKey
  )
  #expect(!otherBucket.matchesRecordedLocation(configuration.recordingMetadata))
}

@Test func hashesS3UploadFilesWithoutLoadingThemAsRequestBodies() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("abc".utf8).write(to: url)
  #expect(
    try S3RequestSigner.payloadHash(fileURL: url)
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  )
}

@Test func directS3SignedPutHeadDeleteRoundTrip() async throws {
  guard let endpointValue = ProcessInfo.processInfo.environment["WAKEONCUE_TEST_S3_ENDPOINT"],
    let endpoint = URL(string: endpointValue)
  else { return }
  let configuration = S3Configuration(
    endpointURL: endpoint,
    region: "us-east-1",
    bucket: "wakeoncue-test",
    prefix: "integration",
    accessKeyID: "wakeoncue-test",
    secretAccessKey: "wakeoncue-test-secret",
    forcePathStyle: true
  )
  let key = "integration/\(UUID().uuidString).txt"
  let payload = Data("direct-s3-pass".utf8)
  var put = try S3RequestSigner.signedRequest(
    method: "PUT",
    objectKey: key,
    contentType: "text/plain",
    payloadHash: S3RequestSigner.payloadHash(payload),
    configuration: configuration
  )
  put.httpBody = payload
  let (_, putResponse) = try await URLSession.shared.data(for: put)
  #expect((putResponse as? HTTPURLResponse)?.statusCode == 200)

  let head = try S3RequestSigner.signedRequest(
    method: "HEAD",
    objectKey: key,
    contentType: "text/plain",
    payloadHash: S3RequestSigner.emptyPayloadHash,
    configuration: configuration
  )
  let (_, headResponse) = try await URLSession.shared.data(for: head)
  #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)

  let get = try S3RequestSigner.signedRequest(
    method: "GET",
    objectKey: key,
    contentType: "text/plain",
    payloadHash: S3RequestSigner.emptyPayloadHash,
    configuration: configuration
  )
  let (downloaded, getResponse) = try await URLSession.shared.data(for: get)
  #expect((getResponse as? HTTPURLResponse)?.statusCode == 200)
  #expect(downloaded == payload)

  let delete = try S3RequestSigner.signedRequest(
    method: "DELETE",
    objectKey: key,
    contentType: "application/octet-stream",
    payloadHash: S3RequestSigner.emptyPayloadHash,
    configuration: configuration
  )
  let (_, deleteResponse) = try await URLSession.shared.data(for: delete)
  #expect((deleteResponse as? HTTPURLResponse)?.statusCode == 204)
}

@Test func identifiesOnlyRecordingsWithUploadedFinalAudio() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let recording = RecordingRecord(
    id: "rec_uploaded_final",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording,
    createPayloadPath: root.appending(path: "create.json").path,
    now: now
  )
  var eligible = try await store.eligibleUploadTasks()
  try await store.claimUploadTask(id: eligible[0].id, backgroundTaskIdentifier: 1)
  try await store.markUploadTaskUploaded(id: eligible[0].id)

  try await store.transition(recordingID: recording.id, to: .finishing, duration: 1)
  try await store.enqueueControlTask(
    recordingID: recording.id,
    kind: .finish,
    payloadPath: root.appending(path: "source.m4a").path
  )
  try await store.transition(recordingID: recording.id, to: .uploading, duration: 1)
  #expect(try await store.recordingsWithUploadedFinalAudio().isEmpty)

  eligible = try await store.eligibleUploadTasks()
  #expect(eligible.count == 1)
  #expect(eligible[0].kind == .finish)
  try await store.claimUploadTask(id: eligible[0].id, backgroundTaskIdentifier: 2)
  try await store.markUploadTaskUploaded(id: eligible[0].id)

  let uploaded = try await store.recordingsWithUploadedFinalAudio()
  #expect(uploaded.map(\.id) == [recording.id])
}

@Test func localRecordingCompletesWithoutCreatingUploadWork() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let recording = RecordingRecord(
    id: "rec_local",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording,
    createPayloadPath: root.appending(path: "create.json").path,
    enqueueUpload: false,
    now: now
  )
  try await store.insertChunk(
    ChunkRecord(
      id: "local_chunk",
      recordingID: recording.id,
      index: 1,
      localPath: root.appending(path: "1.m4a").path,
      checksum: String(repeating: "a", count: 64),
      size: 100,
      startedAt: now,
      duration: 8.5
    ),
    enqueueUpload: false,
    now: now
  )
  try await store.transition(recordingID: recording.id, to: .finishing, duration: 8.5)
  try await store.completeLocally(recordingID: recording.id, duration: 8.5)

  let summary = try await store.summary(recordingID: recording.id)
  #expect(summary.recording.status == .completed)
  #expect(summary.recording.uploadStatus == .completed)
  #expect(summary.recording.pendingChunks == 0)
  #expect(summary.chunks.map(\.status) == [.uploaded])
  #expect(summary.uploadTasks.isEmpty)
  #expect(try await store.activeRecording() == nil)
}

@Test func completingLocallyRepairsLegacyStuckUploadQueue() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let recording = RecordingRecord(
    id: "rec_stuck",
    createdAt: .now,
    startedAt: .now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording,
    createPayloadPath: root.appending(path: "create.json").path
  )
  try await store.insertChunk(
    ChunkRecord(
      id: "stuck_chunk",
      recordingID: recording.id,
      index: 1,
      localPath: root.appending(path: "1.m4a").path,
      checksum: String(repeating: "b", count: 64),
      size: 200,
      startedAt: .now,
      duration: 12
    )
  )
  try await store.transition(recordingID: recording.id, to: .finishing, duration: 12)
  try await store.transition(recordingID: recording.id, to: .uploading, duration: 12)

  try await store.completeLocally(recordingID: recording.id, duration: 12)

  let summary = try await store.summary(recordingID: recording.id)
  #expect(summary.recording.status == .completed)
  #expect(summary.recording.uploadStatus == .completed)
  #expect(summary.recording.pendingChunks == 0)
  #expect(summary.chunks.allSatisfy { $0.status == .uploaded })
  #expect(summary.uploadTasks.allSatisfy { $0.state == .uploaded })
  #expect(try await store.eligibleUploadTasks().isEmpty)
  #expect(try await store.activeRecording() == nil)
}

@Test func persistsDependencyOrderedUploadQueueAndRecovery() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let recording = RecordingRecord(
    id: "rec_store_test",
    createdAt: startedAt,
    startedAt: startedAt,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path)
  for index in 1...2 {
    try await store.insertChunk(
      ChunkRecord(
        id: "chunk_\(index)",
        recordingID: recording.id,
        index: index,
        localPath: root.appending(path: "\(index).m4a").path,
        checksum: String(repeating: "a", count: 64),
        size: 100,
        startedAt: startedAt.addingTimeInterval(Double(index - 1) * 10),
        duration: 10
      )
    )
  }

  var eligible = try await store.eligibleUploadTasks(now: startedAt.addingTimeInterval(1))
  #expect(eligible.map(\.kind) == [.createRecording])
  try await store.claimUploadTask(id: eligible[0].id, backgroundTaskIdentifier: 10)
  try await store.markUploadTaskUploaded(id: eligible[0].id)

  eligible = try await store.eligibleUploadTasks()
  #expect(eligible.count == 2)
  #expect(eligible.allSatisfy { $0.kind == .uploadChunk })
  try await store.claimUploadTask(id: eligible[0].id, backgroundTaskIdentifier: 11)

  let recoveredIDs = try await store.recoverAfterProcessTermination()
  #expect(recoveredIDs == [recording.id])
  let recoveredTask = try await store.uploadTask(id: eligible[0].id)
  #expect(recoveredTask.state == .pending)
  #expect(recoveredTask.backgroundTaskIdentifier == nil)
  #expect(try await store.recording(id: recording.id).status == .finishing)
}

@Test func acknowledgesChunksAndUnlocksFinishOnlyAfterAllDependencies() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let recording = RecordingRecord(
    id: "rec_finish_test",
    createdAt: .now,
    startedAt: .now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path)
  let create = try #require(await store.eligibleUploadTasks().first)
  try await store.markUploadTaskUploaded(id: create.id)

  let chunk = ChunkRecord(
    id: "chunk_only",
    recordingID: recording.id,
    index: 1,
    localPath: root.appending(path: "1.m4a").path,
    checksum: String(repeating: "b", count: 64),
    size: 321,
    startedAt: .now,
    duration: 9.8
  )
  try await store.insertChunk(chunk)
  try await store.transition(recordingID: recording.id, to: .finishing, duration: 9.8)
  try await store.enqueueControlTask(
    recordingID: recording.id,
    kind: .finish,
    payloadPath: root.appending(path: "finish.json").path
  )
  var tasks = try await store.eligibleUploadTasks()
  #expect(tasks.map(\.kind) == [.uploadChunk])
  try await store.markUploadTaskUploaded(id: tasks[0].id)
  tasks = try await store.eligibleUploadTasks()
  #expect(tasks.map(\.kind) == [.finish])
  try await store.markUploadTaskUploaded(id: tasks[0].id)

  let final = try await store.recording(id: recording.id)
  #expect(final.status == .completed)
  #expect(final.uploadStatus == .completed)
  #expect(final.uploadedBytes == 321)
  #expect(final.pendingChunks == 0)
}

@Test func reportsUploadProgressAsRecordingDuration() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let recording = RecordingRecord(
    id: "rec_duration_progress",
    createdAt: .now,
    startedAt: .now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path)
  let create = try #require(await store.eligibleUploadTasks().first)
  try await store.markUploadTaskUploaded(id: create.id)
  for (index, duration) in [(1, 8.25), (2, 4.5)] {
    try await store.insertChunk(
      ChunkRecord(
        id: "progress_\(index)",
        recordingID: recording.id,
        index: index,
        localPath: root.appending(path: "\(index).m4a").path,
        checksum: String(repeating: "f", count: 64),
        size: 100,
        startedAt: .now,
        duration: duration
      )
    )
  }
  let uploads = try await store.eligibleUploadTasks()
  let first = try #require(uploads.first { $0.chunkID == "progress_1" })
  try await store.markUploadTaskUploaded(id: first.id)

  let progress = try await store.syncProgress(recordingID: recording.id)
  #expect(progress.uploadedDuration == 8.25)
  #expect(progress.pendingDuration == 4.5)
}

@Test func preservesActiveBackgroundUploadAndChunkStateDuringRecovery() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_100_000)
  let recording = RecordingRecord(
    id: "rec_active_recovery",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path, now: now)
  let create = try #require(await store.eligibleUploadTasks(now: now).first)
  try await store.markUploadTaskUploaded(id: create.id, now: now)
  try await store.insertChunk(
    ChunkRecord(
      id: "chunk_active",
      recordingID: recording.id,
      index: 1,
      localPath: root.appending(path: "1.m4a").path,
      checksum: String(repeating: "d", count: 64),
      size: 123,
      startedAt: now,
      duration: 10
    ),
    now: now
  )
  let chunkTask = try #require(
    await store.eligibleUploadTasks(now: now).first { $0.kind == .uploadChunk })
  try await store.claimUploadTask(
    id: chunkTask.id, backgroundTaskIdentifier: 42, now: now.addingTimeInterval(1))
  #expect(try await store.chunk(id: "chunk_active").status == .uploading)

  let recovered = try await store.recoverAfterProcessTermination(
    activeUploadTaskIDs: [chunkTask.id], now: now.addingTimeInterval(2))
  #expect(recovered == [recording.id])
  #expect(try await store.recording(id: recording.id).status == .finishing)
  #expect(try await store.uploadTask(id: chunkTask.id).state == .uploading)
  #expect(try await store.uploadTask(id: chunkTask.id).backgroundTaskIdentifier == 42)
  #expect(try await store.chunk(id: "chunk_active").status == .uploading)
}

@Test func recoversCrashInsideFinishingTransitionWindow() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_150_000)
  let recording = RecordingRecord(
    id: "rec_finishing_recovery",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path, now: now)
  try await store.transition(
    recordingID: recording.id,
    to: .finishing,
    duration: 12,
    now: now.addingTimeInterval(12)
  )

  let recovered = try await store.recoverAfterProcessTermination(
    now: now.addingTimeInterval(13))
  #expect(recovered == [recording.id])
  let final = try await store.recording(id: recording.id)
  #expect(final.status == .finishing)
  #expect(final.endedAt == now.addingTimeInterval(12))
}

@Test func serializesPauseAndResumeControlTasks() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_200_000)
  let recording = RecordingRecord(
    id: "rec_control_order",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path, now: now)
  let create = try #require(await store.eligibleUploadTasks(now: now).first)
  try await store.markUploadTaskUploaded(id: create.id, now: now)
  try await store.enqueueControlTask(
    recordingID: recording.id,
    kind: .pause,
    payloadPath: root.appending(path: "pause.json").path,
    now: now.addingTimeInterval(1)
  )
  try await store.enqueueControlTask(
    recordingID: recording.id,
    kind: .resume,
    payloadPath: root.appending(path: "resume.json").path,
    now: now.addingTimeInterval(2)
  )

  var eligible = try await store.eligibleUploadTasks(now: now.addingTimeInterval(3))
  #expect(eligible.map(\.kind) == [.pause])
  try await store.markUploadTaskUploaded(id: eligible[0].id, now: now.addingTimeInterval(3))
  eligible = try await store.eligibleUploadTasks(now: now.addingTimeInterval(4))
  #expect(eligible.map(\.kind) == [.resume])
}

@Test func gatesFailedChunkRetryAndAcknowledgesItOnce() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_300_000)
  let recording = RecordingRecord(
    id: "rec_retry",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: root.appending(path: "source.caf").path,
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording, createPayloadPath: root.appending(path: "create.json").path, now: now)
  let create = try #require(await store.eligibleUploadTasks(now: now).first)
  try await store.markUploadTaskUploaded(id: create.id, now: now)
  try await store.insertChunk(
    ChunkRecord(
      id: "chunk_retry",
      recordingID: recording.id,
      index: 1,
      localPath: root.appending(path: "1.m4a").path,
      checksum: String(repeating: "e", count: 64),
      size: 456,
      startedAt: now,
      duration: 10
    ),
    now: now
  )
  let task = try #require(await store.eligibleUploadTasks(now: now).first)
  try await store.claimUploadTask(
    id: task.id, backgroundTaskIdentifier: 7, now: now.addingTimeInterval(1))
  let retryAt = now.addingTimeInterval(30)
  try await store.markUploadTaskFailed(
    id: task.id, error: "offline", retryAt: retryAt, now: now.addingTimeInterval(2))

  #expect(try await store.uploadTask(id: task.id).retryCount == 1)
  #expect(try await store.chunk(id: "chunk_retry").status == .failed)
  #expect(try await store.chunk(id: "chunk_retry").retryCount == 1)
  #expect(try await store.eligibleUploadTasks(now: retryAt.addingTimeInterval(-1)).isEmpty)
  #expect(
    try await store.nextUploadRetryDate(after: retryAt.addingTimeInterval(-1)) == retryAt
  )
  #expect(try await store.eligibleUploadTasks(now: retryAt).map(\.id) == [task.id])
  #expect(try await store.nextUploadRetryDate(after: retryAt) == nil)

  try await store.claimUploadTask(
    id: task.id, backgroundTaskIdentifier: 8, now: retryAt)
  #expect(try await store.chunk(id: "chunk_retry").status == .uploading)
  try await store.markUploadTaskUploaded(id: task.id, now: retryAt.addingTimeInterval(1))
  try await store.markUploadTaskUploaded(id: task.id, now: retryAt.addingTimeInterval(2))
  let final = try await store.recording(id: recording.id)
  #expect(try await store.chunk(id: "chunk_retry").status == .uploaded)
  #expect(final.uploadedBytes == 456)
  #expect(final.pendingChunks == 0)
}

@Test func rebasesPersistedPathsAfterApplicationContainerChanges() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try RecordingStore(databaseURL: root.appending(path: "recordings.sqlite"))
  let now = Date(timeIntervalSince1970: 1_700_400_000)
  let oldRoot = "/old-container/Library/Application Support/RecordingData"
  let newRoot = root.appending(path: "RecordingData")
  let recording = RecordingRecord(
    id: "rec_rebase",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: "\(oldRoot)/recordings/rec_rebase/source.caf",
    deviceModel: "test",
    appVersion: "1"
  )
  try await store.createRecording(
    recording,
    createPayloadPath: "\(oldRoot)/recordings/rec_rebase/queue/create.json",
    now: now
  )
  let create = try #require(await store.eligibleUploadTasks(now: now).first)
  try await store.claimUploadTask(id: create.id, backgroundTaskIdentifier: 1, now: now)
  try await store.markUploadTaskFailed(
    id: create.id,
    error: "Upload source file is missing",
    retryAt: .distantFuture,
    now: now
  )

  try await store.rebaseLocalFilePaths(to: newRoot, now: now.addingTimeInterval(1))

  let rebasedRecording = try await store.recording(id: recording.id)
  let rebasedTask = try await store.uploadTask(id: create.id)
  #expect(
    rebasedRecording.localAudioPath
      == newRoot.appending(path: "recordings/rec_rebase/source.caf").path
  )
  #expect(
    rebasedTask.localFilePath
      == newRoot.appending(path: "recordings/rec_rebase/queue/create.json").path
  )
  #expect(rebasedTask.state == .pending)
  #expect(rebasedTask.nextRetryAt == nil)
  #expect(rebasedTask.lastError == nil)
}

@Test func buildsIdempotentChunkRequest() throws {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let recording = RecordingRecord(
    id: "rec_request",
    createdAt: now,
    startedAt: now,
    status: .recording,
    localAudioPath: "/tmp/source.caf",
    deviceModel: "test",
    appVersion: "1"
  )
  let chunk = ChunkRecord(
    id: "chunk_request",
    recordingID: recording.id,
    index: 7,
    localPath: "/tmp/7.m4a",
    checksum: String(repeating: "c", count: 64),
    size: 20,
    startedAt: now,
    duration: 10
  )
  let task = UploadTaskRecord(
    id: "task_request",
    recordingID: recording.id,
    chunkID: chunk.id,
    kind: .uploadChunk,
    deduplicationKey: "rec_request:chunk:7",
    localFilePath: chunk.localPath,
    createdAt: now,
    updatedAt: now
  )
  let request = try UploadRequestBuilder.makeRequest(
    task: task,
    recording: recording,
    chunk: chunk,
    configuration: APIConfiguration(
      baseURL: URL(string: "https://recordings.example.test/")!, bearerToken: "secret"
    )
  )
  #expect(request.httpMethod == "PUT")
  #expect(request.url?.path == "/v1/recordings/rec_request/chunks/7")
  #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == task.id)
  #expect(request.value(forHTTPHeaderField: "X-Chunk-Checksum") == chunk.checksum)
}

@Test func validatesExactChunkAndLifecycleAcknowledgements() throws {
  let now = Date(timeIntervalSince1970: 1_700_400_000)
  let chunk = ChunkRecord(
    id: "chunk_ack",
    recordingID: "rec_ack",
    index: 3,
    localPath: "/tmp/3.m4a",
    checksum: String(repeating: "f", count: 64),
    size: 789,
    startedAt: now,
    duration: 10
  )
  let chunkTask = UploadTaskRecord(
    id: "task_ack",
    recordingID: chunk.recordingID,
    chunkID: chunk.id,
    kind: .uploadChunk,
    deduplicationKey: "rec_ack:chunk:3",
    localFilePath: chunk.localPath,
    createdAt: now,
    updatedAt: now
  )
  let validChunkResponse = Data(
    """
    {"ack":true,"recording_id":"rec_ack","chunk_index":3,"checksum":"\(chunk.checksum)","size":789,"duplicate":false}
    """.utf8
  )
  try UploadResponseValidator.validate(validChunkResponse, task: chunkTask, chunk: chunk)

  let wrongChunkResponse = Data(
    """
    {"ack":true,"recording_id":"rec_ack","chunk_index":4,"checksum":"\(chunk.checksum)","size":789,"duplicate":false}
    """.utf8
  )
  #expect(throws: UploadResponseValidationError.mismatchedChunk) {
    try UploadResponseValidator.validate(wrongChunkResponse, task: chunkTask, chunk: chunk)
  }

  let finishTask = UploadTaskRecord(
    id: "task_finish_ack",
    recordingID: chunk.recordingID,
    kind: .finish,
    deduplicationKey: "rec_ack:finish",
    localFilePath: "/tmp/finish.json",
    createdAt: now,
    updatedAt: now
  )
  try UploadResponseValidator.validate(
    Data("{\"id\":\"rec_ack\",\"status\":\"COMPLETED\"}".utf8),
    task: finishTask,
    chunk: nil
  )
  #expect(
    throws: UploadResponseValidationError.unexpectedRecordingStatus(
      expected: .completed,
      actual: .uploading
    )
  ) {
    try UploadResponseValidator.validate(
      Data("{\"id\":\"rec_ack\",\"status\":\"UPLOADING\"}".utf8),
      task: finishTask,
      chunk: nil
    )
  }
}
