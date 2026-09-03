import Foundation

public enum RealtimeProtocol {
  public static let version = 1
  public static let sampleRate = 24_000
  public static let channels = 1
  public static let encoding = "pcm_s16le"
}

public struct RealtimeSessionRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let recordingID: String
  public let language: String?
  public let audio: RealtimeAudioFormat

  public init(recordingID: String, language: String?) {
    protocolVersion = RealtimeProtocol.version
    self.recordingID = recordingID
    self.language = language
    audio = RealtimeAudioFormat(
      encoding: RealtimeProtocol.encoding,
      sampleRate: RealtimeProtocol.sampleRate,
      channels: RealtimeProtocol.channels
    )
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case recordingID = "recording_id"
    case language
    case audio
  }
}

public struct RealtimeAudioFormat: Codable, Equatable, Sendable {
  public let encoding: String
  public let sampleRate: Int
  public let channels: Int

  public init(encoding: String, sampleRate: Int, channels: Int) {
    self.encoding = encoding
    self.sampleRate = sampleRate
    self.channels = channels
  }

  enum CodingKeys: String, CodingKey {
    case encoding
    case sampleRate = "sample_rate"
    case channels
  }
}

public struct RealtimeSessionResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let sessionID: String
  public let websocketURL: URL
  public let sessionToken: String
  public let expiresAt: String

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case sessionID = "session_id"
    case websocketURL = "websocket_url"
    case sessionToken = "session_token"
    case expiresAt = "expires_at"
  }
}

public struct RealtimeSpeaker: Codable, Equatable, Sendable {
  public let clusterID: String
  public let personID: String?
  public let displayName: String
  public let confidence: Double?

  public init(
    clusterID: String,
    personID: String? = nil,
    displayName: String,
    confidence: Double? = nil
  ) {
    self.clusterID = clusterID
    self.personID = personID
    self.displayName = displayName
    self.confidence = confidence
  }

  enum CodingKeys: String, CodingKey {
    case clusterID = "cluster_id"
    case personID = "person_id"
    case displayName = "display_name"
    case confidence
  }
}

public struct RealtimeTranscriptEvent: Codable, Equatable, Identifiable, Sendable {
  public let protocolVersion: Int
  public let type: String
  public let recordingID: String
  public let segmentID: String
  public let revision: Int
  public let startMilliseconds: Int
  public let endMilliseconds: Int
  public let text: String
  public let isFinal: Bool
  public let speaker: RealtimeSpeaker?

  public var id: String { segmentID }

  public init(
    protocolVersion: Int = RealtimeProtocol.version,
    type: String = "transcript.upsert",
    recordingID: String,
    segmentID: String,
    revision: Int,
    startMilliseconds: Int,
    endMilliseconds: Int,
    text: String,
    isFinal: Bool,
    speaker: RealtimeSpeaker?
  ) {
    self.protocolVersion = protocolVersion
    self.type = type
    self.recordingID = recordingID
    self.segmentID = segmentID
    self.revision = revision
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
    self.isFinal = isFinal
    self.speaker = speaker
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case type
    case recordingID = "recording_id"
    case segmentID = "segment_id"
    case revision
    case startMilliseconds = "start_ms"
    case endMilliseconds = "end_ms"
    case text
    case isFinal = "is_final"
    case speaker
  }
}

public struct RealtimeServerEnvelope: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let type: String
  public let status: String?
  public let message: String?

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case type
    case status
    case message
  }
}
