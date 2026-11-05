import Foundation

public enum RecordingStatus: String, Codable, CaseIterable, Sendable {
  case ready = "READY"
  case recording = "RECORDING"
  case paused = "PAUSED"
  case finishing = "FINISHING"
  case uploading = "UPLOADING"
  case completed = "COMPLETED"
  case failed = "FAILED"
}

public enum UploadStatus: String, Codable, CaseIterable, Sendable {
  case pending = "PENDING"
  case uploading = "UPLOADING"
  case completed = "COMPLETED"
  case failed = "FAILED"
}

public enum ChunkStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case uploading
  case uploaded
  case failed
}

public enum UploadTaskKind: String, Codable, CaseIterable, Sendable {
  case createRecording
  case uploadChunk
  case pause
  case resume
  case finish
  case transcript
}

public enum UploadTaskState: String, Codable, CaseIterable, Sendable {
  case pending
  case uploading
  case uploaded
  case failed
}

public struct RecordingSyncProgress: Equatable, Sendable {
  public let uploadedDuration: TimeInterval
  public let pendingDuration: TimeInterval

  public init(uploadedDuration: TimeInterval = 0, pendingDuration: TimeInterval = 0) {
    self.uploadedDuration = max(0, uploadedDuration)
    self.pendingDuration = max(0, pendingDuration)
  }

  public func includingUnindexedDuration(_ totalDuration: TimeInterval) -> Self {
    let accountedDuration = uploadedDuration + pendingDuration
    return Self(
      uploadedDuration: uploadedDuration,
      pendingDuration: pendingDuration + max(0, totalDuration - accountedDuration)
    )
  }
}

public struct RecordingRecord: Identifiable, Codable, Equatable, Sendable {
  public static let titleMetadataKey = "title"
  public static let automaticTitleMetadataKey = "automatic_title"
  public static let overviewMetadataKey = "summary_overview"
  public static let deletedAtMetadataKey = "deleted_at"
  public static let trashExpirySeenAtMetadataKey = "trash_expiry_seen_at"

  public let id: String
  public let createdAt: Date
  public let startedAt: Date
  public var endedAt: Date?
  public var duration: TimeInterval
  public var status: RecordingStatus
  public let localAudioPath: String
  public var uploadStatus: UploadStatus
  public var uploadedBytes: Int64
  public var pendingChunks: Int
  public let deviceModel: String
  public let appVersion: String
  public let metadata: [String: String]

  public init(
    id: String,
    createdAt: Date,
    startedAt: Date,
    endedAt: Date? = nil,
    duration: TimeInterval = 0,
    status: RecordingStatus,
    localAudioPath: String,
    uploadStatus: UploadStatus = .pending,
    uploadedBytes: Int64 = 0,
    pendingChunks: Int = 0,
    deviceModel: String,
    appVersion: String,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.duration = duration
    self.status = status
    self.localAudioPath = localAudioPath
    self.uploadStatus = uploadStatus
    self.uploadedBytes = uploadedBytes
    self.pendingChunks = pendingChunks
    self.deviceModel = deviceModel
    self.appVersion = appVersion
    self.metadata = metadata
  }

  /// A user-authored title stored durably with the recording metadata.
  public var title: String? {
    trimmedMetadata(Self.titleMetadataKey)
  }

  /// A title taken from the recording's summary. It never replaces a title in `title`, so
  /// removing a user's title falls back to it and regenerating a summary can update it.
  public var automaticTitle: String? {
    trimmedMetadata(Self.automaticTitleMetadataKey)
  }

  /// The title to show and search, when the recording has one.
  public var resolvedTitle: String? {
    title ?? automaticTitle
  }

  /// A short description taken from the recording's summary.
  public var overview: String? {
    trimmedMetadata(Self.overviewMetadataKey)
  }

  /// Whether the recording is in Recently Deleted. Matches the store's filter: the key decides,
  /// even when its date cannot be read.
  public var isDeleted: Bool {
    metadata[Self.deletedAtMetadataKey] != nil
  }

  /// When the recording moved to Recently Deleted; nil in the library or if the date is unreadable.
  public var deletedAt: Date? {
    metadataDate(Self.deletedAtMetadataKey)
  }

  /// When a purge first found this recording past its retention period.
  public var trashExpirySeenAt: Date? {
    metadataDate(Self.trashExpirySeenAtMetadataKey)
  }

  private func metadataDate(_ key: String) -> Date? {
    guard let seconds = metadata[key].flatMap(TimeInterval.init), seconds.isFinite else {
      return nil
    }
    return Date(timeIntervalSince1970: seconds)
  }

  private func trimmedMetadata(_ key: String) -> String? {
    guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}

public struct ChunkRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let recordingID: String
  public let index: Int
  public let localPath: String
  public let checksum: String
  public let size: Int64
  public let startedAt: Date
  public let duration: TimeInterval
  public var status: ChunkStatus
  public var retryCount: Int
  public var lastError: String?

  public init(
    id: String,
    recordingID: String,
    index: Int,
    localPath: String,
    checksum: String,
    size: Int64,
    startedAt: Date,
    duration: TimeInterval,
    status: ChunkStatus = .pending,
    retryCount: Int = 0,
    lastError: String? = nil
  ) {
    self.id = id
    self.recordingID = recordingID
    self.index = index
    self.localPath = localPath
    self.checksum = checksum
    self.size = size
    self.startedAt = startedAt
    self.duration = duration
    self.status = status
    self.retryCount = retryCount
    self.lastError = lastError
  }
}

public struct UploadTaskRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let recordingID: String
  public let chunkID: String?
  public let kind: UploadTaskKind
  public let deduplicationKey: String
  public let localFilePath: String
  public var state: UploadTaskState
  public var retryCount: Int
  public var nextRetryAt: Date?
  public var lastError: String?
  public var backgroundTaskIdentifier: Int?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    recordingID: String,
    chunkID: String? = nil,
    kind: UploadTaskKind,
    deduplicationKey: String,
    localFilePath: String,
    state: UploadTaskState = .pending,
    retryCount: Int = 0,
    nextRetryAt: Date? = nil,
    lastError: String? = nil,
    backgroundTaskIdentifier: Int? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.recordingID = recordingID
    self.chunkID = chunkID
    self.kind = kind
    self.deduplicationKey = deduplicationKey
    self.localFilePath = localFilePath
    self.state = state
    self.retryCount = retryCount
    self.nextRetryAt = nextRetryAt
    self.lastError = lastError
    self.backgroundTaskIdentifier = backgroundTaskIdentifier
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RecordingSummary: Codable, Equatable, Sendable {
  public let recording: RecordingRecord
  public let chunks: [ChunkRecord]
  public let uploadTasks: [UploadTaskRecord]
}
