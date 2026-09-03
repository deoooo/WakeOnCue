import Foundation
import SQLite3

public enum RecordingStoreError: Error, LocalizedError, Sendable {
  case sqlite(String)
  case notFound(String)
  case invalidData(String)

  public var errorDescription: String? {
    switch self {
    case .sqlite(let message), .invalidData(let message): message
    case .notFound(let identifier): "Record not found: \(identifier)"
    }
  }
}

public actor RecordingStore {
  private let connection: SQLiteConnection
  private var database: OpaquePointer { connection.pointer }

  public init(databaseURL: URL) throws {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var connection: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &connection,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let connection else {
      let message =
        connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite"
      if let connection { sqlite3_close(connection) }
      throw RecordingStoreError.sqlite(message)
    }
    do {
      try Self.execute(connection, "PRAGMA journal_mode = WAL")
      try Self.execute(connection, "PRAGMA synchronous = FULL")
      try Self.execute(connection, "PRAGMA foreign_keys = ON")
      try Self.migrate(connection)
    } catch {
      sqlite3_close(connection)
      throw error
    }
    self.connection = SQLiteConnection(connection)
  }

  public func createRecording(
    _ recording: RecordingRecord,
    createPayloadPath: String,
    enqueueUpload: Bool = true,
    now: Date = Date()
  ) throws {
    try transaction {
      let metadata = try Self.encodeMetadata(recording.metadata)
      try run(
        """
        INSERT INTO recordings (
            id, created_at, started_at, ended_at, duration, status,
            local_audio_path, upload_status, uploaded_bytes, pending_chunks,
            device_model, app_version, metadata_json, updated_at
        ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(recording.id), .double(recording.createdAt.timeIntervalSince1970),
          .double(recording.startedAt.timeIntervalSince1970), .double(recording.duration),
          .text(recording.status.rawValue), .text(recording.localAudioPath),
          .text(recording.uploadStatus.rawValue), .int(recording.uploadedBytes),
          .int(Int64(recording.pendingChunks)), .text(recording.deviceModel),
          .text(recording.appVersion), .text(metadata),
          .double(now.timeIntervalSince1970),
        ]
      )
      if enqueueUpload {
        try insertUploadTask(
          UploadTaskRecord(
            id: UUID().uuidString,
            recordingID: recording.id,
            kind: .createRecording,
            deduplicationKey: "\(recording.id):create",
            localFilePath: createPayloadPath,
            createdAt: now,
            updatedAt: now
          )
        )
      }
    }
  }

  public func recording(id: String) throws -> RecordingRecord {
    guard
      let recording = try queryRecordings(
        "SELECT * FROM recordings WHERE id = ?", [.text(id)]
      ).first
    else {
      throw RecordingStoreError.notFound(id)
    }
    return recording
  }

  public func recordings(limit: Int = 100) throws -> [RecordingRecord] {
    try queryRecordings(
      "SELECT * FROM recordings ORDER BY created_at DESC LIMIT ?",
      [.int(Int64(max(1, limit)))]
    )
  }

  /// Recordings whose complete, shareable M4A has been acknowledged by S3.
  public func recordingsWithUploadedFinalAudio() throws -> [RecordingRecord] {
    try queryRecordings(
      """
      SELECT recordings.* FROM recordings
      WHERE status = 'COMPLETED'
        AND EXISTS (
          SELECT 1 FROM upload_tasks
          WHERE upload_tasks.recording_id = recordings.id
            AND upload_tasks.kind = 'finish'
            AND upload_tasks.state = 'uploaded'
        )
      ORDER BY created_at DESC
      """,
      []
    )
  }

  public func activeRecording() throws -> RecordingRecord? {
    try queryRecordings(
      """
      SELECT * FROM recordings
      WHERE status IN ('RECORDING', 'PAUSED', 'FINISHING', 'UPLOADING')
      ORDER BY created_at DESC LIMIT 1
      """,
      []
    ).first
  }

  public func rebaseLocalFilePaths(to dataRoot: URL, now: Date = Date()) throws {
    let rootPath = dataRoot.standardizedFileURL.path
    let pathPrefix = rootPath + "/recordings/"
    try transaction {
      try run(
        """
        UPDATE recordings
        SET local_audio_path = ? || substr(local_audio_path, instr(local_audio_path, '/recordings/') + 12),
            updated_at = ?
        WHERE instr(local_audio_path, '/recordings/') > 0
          AND local_audio_path NOT LIKE ?
        """,
        [.text(pathPrefix), .double(now.timeIntervalSince1970), .text(pathPrefix + "%")]
      )
      try run(
        """
        UPDATE chunks
        SET local_path = ? || substr(local_path, instr(local_path, '/recordings/') + 12),
            updated_at = ?
        WHERE instr(local_path, '/recordings/') > 0
          AND local_path NOT LIKE ?
        """,
        [.text(pathPrefix), .double(now.timeIntervalSince1970), .text(pathPrefix + "%")]
      )
      try run(
        """
        UPDATE upload_tasks
        SET local_file_path = ? || substr(local_file_path, instr(local_file_path, '/recordings/') + 12),
            state = CASE WHEN last_error = 'Upload source file is missing' THEN 'pending' ELSE state END,
            next_retry_at = CASE WHEN last_error = 'Upload source file is missing' THEN NULL ELSE next_retry_at END,
            last_error = CASE WHEN last_error = 'Upload source file is missing' THEN NULL ELSE last_error END,
            updated_at = ?
        WHERE instr(local_file_path, '/recordings/') > 0
          AND local_file_path NOT LIKE ?
        """,
        [.text(pathPrefix), .double(now.timeIntervalSince1970), .text(pathPrefix + "%")]
      )
    }
  }

  public func transition(
    recordingID: String,
    to status: RecordingStatus,
    duration: TimeInterval,
    now: Date = Date()
  ) throws {
    let current = try recording(id: recordingID)
    try RecordingStateMachine.validate(from: current.status, to: status)
    let endedAt: SQLiteValue = status == .finishing ? .double(now.timeIntervalSince1970) : .null
    try run(
      """
      UPDATE recordings
      SET status = ?, duration = ?, ended_at = COALESCE(?, ended_at), updated_at = ?
      WHERE id = ?
      """,
      [
        .text(status.rawValue), .double(duration), endedAt,
        .double(now.timeIntervalSince1970), .text(recordingID),
      ]
    )
  }

  public func enqueueControlTask(
    recordingID: String,
    kind: UploadTaskKind,
    payloadPath: String,
    now: Date = Date()
  ) throws {
    guard [.pause, .resume, .finish].contains(kind) else {
      throw RecordingStoreError.invalidData("Control task kind required")
    }
    let suffix = kind == .finish ? "finish" : "\(kind.rawValue):\(now.timeIntervalSince1970)"
    try insertUploadTask(
      UploadTaskRecord(
        id: UUID().uuidString,
        recordingID: recordingID,
        kind: kind,
        deduplicationKey: "\(recordingID):\(suffix)",
        localFilePath: payloadPath,
        createdAt: now,
        updatedAt: now
      )
    )
  }

  public func enqueueTranscriptTask(
    recordingID: String,
    transcriptPath: String,
    now: Date = Date()
  ) throws {
    try insertUploadTask(
      UploadTaskRecord(
        id: UUID().uuidString,
        recordingID: recordingID,
        kind: .transcript,
        deduplicationKey: "\(recordingID):transcript:\(now.timeIntervalSince1970)",
        localFilePath: transcriptPath,
        createdAt: now,
        updatedAt: now
      )
    )
  }

  public func insertChunk(
    _ chunk: ChunkRecord,
    enqueueUpload: Bool = true,
    now: Date = Date()
  ) throws {
    guard chunk.index > 0 else {
      throw RecordingStoreError.invalidData("Chunk index must be greater than zero")
    }
    try transaction {
      try run(
        """
        INSERT INTO chunks (
            id, recording_id, chunk_index, local_path, checksum, size,
            started_at, duration, status, retry_count, last_error, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(chunk.id), .text(chunk.recordingID), .int(Int64(chunk.index)),
          .text(chunk.localPath), .text(chunk.checksum), .int(chunk.size),
          .double(chunk.startedAt.timeIntervalSince1970), .double(chunk.duration),
          .text(enqueueUpload ? chunk.status.rawValue : ChunkStatus.uploaded.rawValue),
          .int(Int64(chunk.retryCount)),
          chunk.lastError.map(SQLiteValue.text) ?? .null,
          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
        ]
      )
      if enqueueUpload {
        try run(
          """
          UPDATE recordings
          SET pending_chunks = pending_chunks + 1,
              duration = (
                  SELECT COALESCE(SUM(duration), 0) FROM chunks WHERE recording_id = ?
              ),
              upload_status = 'UPLOADING', updated_at = ?
          WHERE id = ?
          """,
          [
            .text(chunk.recordingID), .double(now.timeIntervalSince1970),
            .text(chunk.recordingID),
          ]
        )
        try insertUploadTask(
          UploadTaskRecord(
            id: UUID().uuidString,
            recordingID: chunk.recordingID,
            chunkID: chunk.id,
            kind: .uploadChunk,
            deduplicationKey: "\(chunk.recordingID):chunk:\(chunk.index)",
            localFilePath: chunk.localPath,
            createdAt: now,
            updatedAt: now
          )
        )
      } else {
        try run(
          """
          UPDATE recordings
          SET duration = (
                  SELECT COALESCE(SUM(duration), 0) FROM chunks WHERE recording_id = ?
              ),
              updated_at = ?
          WHERE id = ?
          """,
          [
            .text(chunk.recordingID), .double(now.timeIntervalSince1970),
            .text(chunk.recordingID),
          ]
        )
      }
    }
  }

  /// Makes the durable on-device copy terminal without waiting for a remote acknowledgement.
  /// Existing upload rows are retired so a recording can never remain locked in a sync state.
  public func completeLocally(
    recordingID: String,
    duration: TimeInterval,
    now: Date = Date()
  ) throws {
    let current = try recording(id: recordingID)
    guard current.status != .completed else { return }
    guard [.recording, .paused, .finishing, .uploading, .failed].contains(current.status) else {
      throw RecordingStoreError.invalidData(
        "Recording cannot be completed locally from \(current.status.rawValue)"
      )
    }
    try transaction {
      try run(
        """
        UPDATE recordings
        SET status = 'COMPLETED', upload_status = 'COMPLETED',
            ended_at = COALESCE(ended_at, ?), duration = ?, pending_chunks = 0,
            updated_at = ?
        WHERE id = ?
        """,
        [
          .double(now.timeIntervalSince1970), .double(max(0, duration)),
          .double(now.timeIntervalSince1970), .text(recordingID),
        ]
      )
      try run(
        """
        UPDATE chunks
        SET status = 'uploaded', last_error = NULL, updated_at = ?
        WHERE recording_id = ?
        """,
        [.double(now.timeIntervalSince1970), .text(recordingID)]
      )
      try run(
        """
        UPDATE upload_tasks
        SET state = 'uploaded', next_retry_at = NULL, last_error = NULL,
            background_task_identifier = NULL, updated_at = ?
        WHERE recording_id = ?
        """,
        [.double(now.timeIntervalSince1970), .text(recordingID)]
      )
    }
  }

  public func chunk(id: String) throws -> ChunkRecord {
    guard let chunk = try queryChunks("SELECT * FROM chunks WHERE id = ?", [.text(id)]).first else {
      throw RecordingStoreError.notFound(id)
    }
    return chunk
  }

  public func chunks(recordingID: String) throws -> [ChunkRecord] {
    try queryChunks(
      "SELECT * FROM chunks WHERE recording_id = ? ORDER BY chunk_index", [.text(recordingID)]
    )
  }

  public func syncProgress(recordingID: String) throws -> RecordingSyncProgress {
    let records = try chunks(recordingID: recordingID)
    return RecordingSyncProgress(
      uploadedDuration: records.filter { $0.status == .uploaded }.reduce(0) { $0 + $1.duration },
      pendingDuration: records.filter { $0.status != .uploaded }.reduce(0) { $0 + $1.duration }
    )
  }

  public func uploadTask(id: String) throws -> UploadTaskRecord {
    guard
      let task = try queryUploadTasks(
        "SELECT * FROM upload_tasks WHERE id = ?", [.text(id)]
      ).first
    else {
      throw RecordingStoreError.notFound(id)
    }
    return task
  }

  public func eligibleUploadTasks(now: Date = Date(), limit: Int = 16) throws -> [UploadTaskRecord]
  {
    let candidates = try queryUploadTasks(
      """
      SELECT * FROM upload_tasks
      WHERE state IN ('pending', 'failed')
        AND (next_retry_at IS NULL OR next_retry_at <= ?)
      ORDER BY created_at, id
      LIMIT ?
      """,
      [.double(now.timeIntervalSince1970), .int(Int64(max(1, limit * 4)))]
    )
    var eligible: [UploadTaskRecord] = []
    for task in candidates {
      guard try dependenciesSatisfied(for: task) else { continue }
      eligible.append(task)
      if eligible.count == limit { break }
    }
    return eligible
  }

  public func nextUploadRetryDate(after now: Date = Date()) throws -> Date? {
    try queryUploadTasks(
      """
      SELECT * FROM upload_tasks
      WHERE state = 'failed' AND next_retry_at > ?
      ORDER BY next_retry_at, created_at, id
      LIMIT 1
      """,
      [.double(now.timeIntervalSince1970)]
    ).first?.nextRetryAt
  }

  public func claimUploadTask(
    id: String,
    backgroundTaskIdentifier: Int,
    now: Date = Date()
  ) throws {
    let task = try uploadTask(id: id)
    guard task.state == .pending || task.state == .failed else { return }
    try transaction {
      try run(
        """
        UPDATE upload_tasks
        SET state = 'uploading', background_task_identifier = ?, last_error = NULL, updated_at = ?
        WHERE id = ? AND state IN ('pending', 'failed')
        """,
        [
          .int(Int64(backgroundTaskIdentifier)), .double(now.timeIntervalSince1970), .text(id),
        ]
      )
      if let chunkID = task.chunkID {
        try run(
          """
          UPDATE chunks
          SET status = 'uploading', last_error = NULL, updated_at = ?
          WHERE id = ?
          """,
          [.double(now.timeIntervalSince1970), .text(chunkID)]
        )
      }
      try run(
        """
        UPDATE recordings
        SET upload_status = 'UPLOADING', updated_at = ?
        WHERE id = ?
        """,
        [.double(now.timeIntervalSince1970), .text(task.recordingID)]
      )
    }
  }

  public func markUploadTaskUploaded(id: String, now: Date = Date()) throws {
    let task = try uploadTask(id: id)
    guard task.state != .uploaded else { return }
    try transaction {
      try run(
        """
        UPDATE upload_tasks
        SET state = 'uploaded', background_task_identifier = NULL,
            next_retry_at = NULL, last_error = NULL, updated_at = ?
        WHERE id = ?
        """,
        [.double(now.timeIntervalSince1970), .text(id)]
      )
      if let chunkID = task.chunkID {
        let chunk = try self.chunk(id: chunkID)
        try run(
          """
          UPDATE chunks
          SET status = 'uploaded', last_error = NULL, updated_at = ?
          WHERE id = ?
          """,
          [.double(now.timeIntervalSince1970), .text(chunkID)]
        )
        try run(
          """
          UPDATE recordings
          SET uploaded_bytes = uploaded_bytes + ?,
              pending_chunks = MAX(0, pending_chunks - 1),
              upload_status = 'UPLOADING', updated_at = ?
          WHERE id = ?
          """,
          [
            .int(chunk.size), .double(now.timeIntervalSince1970),
            .text(task.recordingID),
          ]
        )
      }
      if task.kind == .finish {
        try run(
          """
          UPDATE recordings
          SET status = 'COMPLETED', upload_status = 'COMPLETED', updated_at = ?
          WHERE id = ?
          """,
          [.double(now.timeIntervalSince1970), .text(task.recordingID)]
        )
      }
    }
  }

  public func markUploadTaskFailed(
    id: String,
    error: String,
    retryAt: Date? = nil,
    now: Date = Date()
  ) throws {
    let task = try uploadTask(id: id)
    guard task.state != .uploaded else { return }
    let retryCount = task.retryCount + 1
    let backoff = min(pow(2, Double(min(retryCount, 9))), 900)
    let nextRetry = retryAt ?? now.addingTimeInterval(backoff)
    try transaction {
      try run(
        """
        UPDATE upload_tasks
        SET state = 'failed', retry_count = ?, next_retry_at = ?,
            last_error = ?, background_task_identifier = NULL, updated_at = ?
        WHERE id = ?
        """,
        [
          .int(Int64(retryCount)), .double(nextRetry.timeIntervalSince1970),
          .text(error), .double(now.timeIntervalSince1970), .text(id),
        ]
      )
      if let chunkID = task.chunkID {
        try run(
          """
          UPDATE chunks
          SET status = 'failed', retry_count = retry_count + 1,
              last_error = ?, updated_at = ? WHERE id = ?
          """,
          [.text(error), .double(now.timeIntervalSince1970), .text(chunkID)]
        )
      }
      try run(
        """
        UPDATE recordings SET upload_status = 'FAILED', updated_at = ? WHERE id = ?
        """,
        [.double(now.timeIntervalSince1970), .text(task.recordingID)]
      )
    }
  }

  public func recoverAfterProcessTermination(
    activeUploadTaskIDs: Set<String> = [],
    now: Date = Date()
  ) throws -> [String] {
    let interrupted = try queryRecordings(
      "SELECT * FROM recordings WHERE status IN ('RECORDING', 'PAUSED', 'FINISHING')", []
    )
    let orphanedUploads = try queryUploadTasks(
      "SELECT * FROM upload_tasks WHERE state = 'uploading'", []
    ).filter { !activeUploadTaskIDs.contains($0.id) }
    try transaction {
      for task in orphanedUploads {
        try run(
          """
          UPDATE upload_tasks
          SET state = 'pending', background_task_identifier = NULL,
              next_retry_at = NULL, updated_at = ? WHERE id = ?
          """,
          [.double(now.timeIntervalSince1970), .text(task.id)]
        )
        if let chunkID = task.chunkID {
          try run(
            """
            UPDATE chunks SET status = 'pending', updated_at = ? WHERE id = ?
            """,
            [.double(now.timeIntervalSince1970), .text(chunkID)]
          )
        }
      }
      for recording in interrupted {
        try run(
          """
          UPDATE recordings
          SET status = 'FINISHING', ended_at = COALESCE(ended_at, ?),
              upload_status = 'UPLOADING', updated_at = ?
          WHERE id = ?
          """,
          [
            .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
            .text(recording.id),
          ]
        )
      }
    }
    return interrupted.map(\.id)
  }

  public func summary(recordingID: String) throws -> RecordingSummary {
    RecordingSummary(
      recording: try recording(id: recordingID),
      chunks: try chunks(recordingID: recordingID),
      uploadTasks: try queryUploadTasks(
        "SELECT * FROM upload_tasks WHERE recording_id = ? ORDER BY created_at, id",
        [.text(recordingID)]
      )
    )
  }

  private func dependenciesSatisfied(for task: UploadTaskRecord) throws -> Bool {
    if task.kind == .createRecording { return true }
    let createUploaded =
      try scalarInt(
        """
        SELECT COUNT(*) FROM upload_tasks
        WHERE recording_id = ? AND kind = 'createRecording' AND state = 'uploaded'
        """,
        [.text(task.recordingID)]
      ) > 0
    guard createUploaded else { return false }
    if task.kind == .pause || task.kind == .resume {
      return try scalarInt(
        """
        SELECT COUNT(*) FROM upload_tasks
        WHERE recording_id = ?
          AND kind IN ('createRecording', 'pause', 'resume')
          AND state != 'uploaded'
          AND (created_at < ? OR (created_at = ? AND id < ?))
        """,
        [
          .text(task.recordingID), .double(task.createdAt.timeIntervalSince1970),
          .double(task.createdAt.timeIntervalSince1970), .text(task.id),
        ]
      ) == 0
    }
    if task.kind != .finish { return true }
    return try scalarInt(
      """
      SELECT COUNT(*) FROM upload_tasks
      WHERE recording_id = ? AND kind != 'finish' AND state != 'uploaded'
      """,
      [.text(task.recordingID)]
    ) == 0
  }

  private func insertUploadTask(_ task: UploadTaskRecord) throws {
    try run(
      """
      INSERT OR IGNORE INTO upload_tasks (
          id, recording_id, chunk_id, kind, deduplication_key, local_file_path,
          state, retry_count, next_retry_at, last_error,
          background_task_identifier, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(task.id), .text(task.recordingID), task.chunkID.map(SQLiteValue.text) ?? .null,
        .text(task.kind.rawValue), .text(task.deduplicationKey), .text(task.localFilePath),
        .text(task.state.rawValue), .int(Int64(task.retryCount)),
        task.nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        task.lastError.map(SQLiteValue.text) ?? .null,
        task.backgroundTaskIdentifier.map { .int(Int64($0)) } ?? .null,
        .double(task.createdAt.timeIntervalSince1970),
        .double(task.updatedAt.timeIntervalSince1970),
      ]
    )
  }

  private func queryRecordings(_ sql: String, _ values: [SQLiteValue]) throws -> [RecordingRecord] {
    try query(sql, values) { statement in
      let metadataText = Self.text(statement, 12) ?? "{}"
      let metadata = try Self.decodeMetadata(metadataText)
      guard
        let id = Self.text(statement, 0),
        let statusValue = Self.text(statement, 5),
        let status = RecordingStatus(rawValue: statusValue),
        let localPath = Self.text(statement, 6),
        let uploadValue = Self.text(statement, 7),
        let uploadStatus = UploadStatus(rawValue: uploadValue),
        let deviceModel = Self.text(statement, 10),
        let appVersion = Self.text(statement, 11)
      else { throw RecordingStoreError.invalidData("Invalid recording row") }
      return RecordingRecord(
        id: id,
        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
        endedAt: Self.date(statement, 3),
        duration: sqlite3_column_double(statement, 4),
        status: status,
        localAudioPath: localPath,
        uploadStatus: uploadStatus,
        uploadedBytes: sqlite3_column_int64(statement, 8),
        pendingChunks: Int(sqlite3_column_int64(statement, 9)),
        deviceModel: deviceModel,
        appVersion: appVersion,
        metadata: metadata
      )
    }
  }

  private func queryChunks(_ sql: String, _ values: [SQLiteValue]) throws -> [ChunkRecord] {
    try query(sql, values) { statement in
      guard
        let id = Self.text(statement, 0),
        let recordingID = Self.text(statement, 1),
        let localPath = Self.text(statement, 3),
        let checksum = Self.text(statement, 4),
        let statusValue = Self.text(statement, 8),
        let status = ChunkStatus(rawValue: statusValue)
      else { throw RecordingStoreError.invalidData("Invalid chunk row") }
      return ChunkRecord(
        id: id,
        recordingID: recordingID,
        index: Int(sqlite3_column_int64(statement, 2)),
        localPath: localPath,
        checksum: checksum,
        size: sqlite3_column_int64(statement, 5),
        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
        duration: sqlite3_column_double(statement, 7),
        status: status,
        retryCount: Int(sqlite3_column_int64(statement, 9)),
        lastError: Self.text(statement, 10)
      )
    }
  }

  private func queryUploadTasks(_ sql: String, _ values: [SQLiteValue]) throws -> [UploadTaskRecord]
  {
    try query(sql, values) { statement in
      guard
        let id = Self.text(statement, 0),
        let recordingID = Self.text(statement, 1),
        let kindValue = Self.text(statement, 3),
        let kind = UploadTaskKind(rawValue: kindValue),
        let deduplicationKey = Self.text(statement, 4),
        let localFilePath = Self.text(statement, 5),
        let stateValue = Self.text(statement, 6),
        let state = UploadTaskState(rawValue: stateValue)
      else { throw RecordingStoreError.invalidData("Invalid upload task row") }
      let backgroundIdentifier =
        sqlite3_column_type(statement, 10) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, 10))
      return UploadTaskRecord(
        id: id,
        recordingID: recordingID,
        chunkID: Self.text(statement, 2),
        kind: kind,
        deduplicationKey: deduplicationKey,
        localFilePath: localFilePath,
        state: state,
        retryCount: Int(sqlite3_column_int64(statement, 7)),
        nextRetryAt: Self.date(statement, 8),
        lastError: Self.text(statement, 9),
        backgroundTaskIdentifier: backgroundIdentifier,
        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
      )
    }
  }

  private func transaction(_ operation: () throws -> Void) throws {
    try Self.execute(database, "BEGIN IMMEDIATE")
    do {
      try operation()
      try Self.execute(database, "COMMIT")
    } catch {
      try? Self.execute(database, "ROLLBACK")
      throw error
    }
  }

  private func run(_ sql: String, _ values: [SQLiteValue]) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw RecordingStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw RecordingStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
  }

  private func query<T>(
    _ sql: String,
    _ values: [SQLiteValue],
    transform: (OpaquePointer) throws -> T
  ) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw RecordingStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    var rows: [T] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw RecordingStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
      }
      rows.append(try transform(statement))
    }
    return rows
  }

  private func scalarInt(_ sql: String, _ values: [SQLiteValue]) throws -> Int64 {
    try query(sql, values) { sqlite3_column_int64($0, 0) }.first ?? 0
  }

  private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .text(let text):
        result = sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
      case .int(let integer):
        result = sqlite3_bind_int64(statement, index, integer)
      case .double(let double):
        result = sqlite3_bind_double(statement, index, double)
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw RecordingStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
      }
    }
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
      let detail =
        message.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(message)
      throw RecordingStoreError.sqlite(detail)
    }
  }

  private static func migrate(_ database: OpaquePointer) throws {
    try execute(
      database,
      """
      CREATE TABLE IF NOT EXISTS recordings (
          id TEXT PRIMARY KEY,
          created_at REAL NOT NULL,
          started_at REAL NOT NULL,
          ended_at REAL,
          duration REAL NOT NULL,
          status TEXT NOT NULL,
          local_audio_path TEXT NOT NULL,
          upload_status TEXT NOT NULL,
          uploaded_bytes INTEGER NOT NULL,
          pending_chunks INTEGER NOT NULL,
          device_model TEXT NOT NULL,
          app_version TEXT NOT NULL,
          metadata_json TEXT NOT NULL,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS chunks (
          id TEXT PRIMARY KEY,
          recording_id TEXT NOT NULL,
          chunk_index INTEGER NOT NULL,
          local_path TEXT NOT NULL,
          checksum TEXT NOT NULL,
          size INTEGER NOT NULL,
          started_at REAL NOT NULL,
          duration REAL NOT NULL,
          status TEXT NOT NULL,
          retry_count INTEGER NOT NULL,
          last_error TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(recording_id, chunk_index),
          FOREIGN KEY(recording_id) REFERENCES recordings(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS upload_tasks (
          id TEXT PRIMARY KEY,
          recording_id TEXT NOT NULL,
          chunk_id TEXT,
          kind TEXT NOT NULL,
          deduplication_key TEXT NOT NULL UNIQUE,
          local_file_path TEXT NOT NULL,
          state TEXT NOT NULL,
          retry_count INTEGER NOT NULL,
          next_retry_at REAL,
          last_error TEXT,
          background_task_identifier INTEGER,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          FOREIGN KEY(recording_id) REFERENCES recordings(id) ON DELETE CASCADE,
          FOREIGN KEY(chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
      );

      CREATE INDEX IF NOT EXISTS upload_tasks_queue_idx
          ON upload_tasks(state, next_retry_at, created_at);
      """
    )
  }

  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let value = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: value)
  }

  private static func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  private static func encodeMetadata(_ metadata: [String: String]) throws -> String {
    let data = try JSONEncoder().encode(metadata)
    guard let value = String(data: data, encoding: .utf8) else {
      throw RecordingStoreError.invalidData("Metadata is not UTF-8")
    }
    return value
  }

  private static func decodeMetadata(_ value: String) throws -> [String: String] {
    guard let data = value.data(using: .utf8) else {
      throw RecordingStoreError.invalidData("Metadata is not UTF-8")
    }
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteValue {
  case text(String)
  case int(Int64)
  case double(Double)
  case null
}

private final class SQLiteConnection: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    sqlite3_close(pointer)
  }
}
