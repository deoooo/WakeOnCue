import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct APIConfiguration: Codable, Equatable, Sendable {
  public let baseURL: URL
  public let bearerToken: String

  public init(baseURL: URL, bearerToken: String) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
  }
}

public enum UploadRequestError: Error, Equatable, Sendable {
  case missingChunk
  case invalidBaseURL
  case unsupportedTask
}

public enum UploadRequestBuilder {
  public static func makeRequest(
    task: UploadTaskRecord,
    recording: RecordingRecord,
    chunk: ChunkRecord?,
    configuration: APIConfiguration
  ) throws -> URLRequest {
    let relativePath: String
    let method: String
    switch task.kind {
    case .createRecording:
      relativePath = "v1/recordings"
      method = "POST"
    case .uploadChunk:
      guard let chunk else { throw UploadRequestError.missingChunk }
      relativePath = "v1/recordings/\(recording.id)/chunks/\(chunk.index)"
      method = "PUT"
    case .pause:
      relativePath = "v1/recordings/\(recording.id)/pause"
      method = "POST"
    case .resume:
      relativePath = "v1/recordings/\(recording.id)/resume"
      method = "POST"
    case .finish:
      relativePath = "v1/recordings/\(recording.id)/finish"
      method = "POST"
    case .transcript:
      throw UploadRequestError.unsupportedTask
    }
    guard let url = URL(string: relativePath, relativeTo: configuration.baseURL)?.absoluteURL else {
      throw UploadRequestError.invalidBaseURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 60
    request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(task.id, forHTTPHeaderField: "Idempotency-Key")
    if task.kind == .createRecording {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    } else if task.kind == .uploadChunk, let chunk {
      request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
      request.setValue(chunk.checksum, forHTTPHeaderField: "X-Chunk-Checksum")
      request.setValue(
        ISO8601DateFormatter().string(from: chunk.startedAt),
        forHTTPHeaderField: "X-Chunk-Started-At")
      request.setValue(String(chunk.duration), forHTTPHeaderField: "X-Chunk-Duration")
    } else {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
}

public struct ChunkAcknowledgement: Codable, Equatable, Sendable {
  public let ack: Bool
  public let recordingID: String
  public let chunkIndex: Int
  public let checksum: String
  public let size: Int64
  public let duplicate: Bool

  enum CodingKeys: String, CodingKey {
    case ack
    case recordingID = "recording_id"
    case chunkIndex = "chunk_index"
    case checksum
    case size
    case duplicate
  }
}

public struct RecordingAcknowledgement: Decodable, Equatable, Sendable {
  public let id: String
  public let status: RecordingStatus
}

public enum UploadResponseValidationError: Error, Equatable, Sendable {
  case missingChunk
  case malformedResponse
  case mismatchedRecording
  case mismatchedChunk
  case unexpectedRecordingStatus(expected: RecordingStatus, actual: RecordingStatus)
}

public enum UploadResponseValidator {
  public static func validate(
    _ data: Data,
    task: UploadTaskRecord,
    chunk: ChunkRecord?
  ) throws {
    let decoder = JSONDecoder()
    if task.kind == .uploadChunk {
      guard let chunk else { throw UploadResponseValidationError.missingChunk }
      guard let acknowledgement = try? decoder.decode(ChunkAcknowledgement.self, from: data),
        acknowledgement.ack
      else { throw UploadResponseValidationError.malformedResponse }
      guard acknowledgement.recordingID == task.recordingID else {
        throw UploadResponseValidationError.mismatchedRecording
      }
      guard acknowledgement.chunkIndex == chunk.index,
        acknowledgement.checksum == chunk.checksum,
        acknowledgement.size == chunk.size
      else { throw UploadResponseValidationError.mismatchedChunk }
      return
    }

    guard let acknowledgement = try? decoder.decode(RecordingAcknowledgement.self, from: data)
    else { throw UploadResponseValidationError.malformedResponse }
    guard acknowledgement.id == task.recordingID else {
      throw UploadResponseValidationError.mismatchedRecording
    }
    let expectedStatus: RecordingStatus
    switch task.kind {
    case .createRecording, .resume: expectedStatus = .recording
    case .pause: expectedStatus = .paused
    case .finish: expectedStatus = .completed
    case .uploadChunk: return
    case .transcript: return
    }
    guard acknowledgement.status == expectedStatus else {
      throw UploadResponseValidationError.unexpectedRecordingStatus(
        expected: expectedStatus,
        actual: acknowledgement.status
      )
    }
  }
}

public struct CreateRecordingPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let startedAt: String
  public let deviceModel: String
  public let appVersion: String
  public let metadata: [String: String]

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case startedAt = "started_at"
    case deviceModel = "device_model"
    case appVersion = "app_version"
    case metadata
  }

  public init(recording: RecordingRecord) {
    let formatter = ISO8601DateFormatter()
    id = recording.id
    createdAt = formatter.string(from: recording.createdAt)
    startedAt = formatter.string(from: recording.startedAt)
    deviceModel = recording.deviceModel
    appVersion = recording.appVersion
    metadata = recording.metadata
  }
}
