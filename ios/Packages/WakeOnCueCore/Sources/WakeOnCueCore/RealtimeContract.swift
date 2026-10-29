import Foundation

public enum RealtimeProtocol {
  public static let version = 1
  public static let sampleRate = 24_000
  public static let channels = 1
  public static let encoding = "pcm_s16le"
}

/// The audio source of a realtime session. A recording captured from several sources opens
/// one session per channel with the same recording ID; nil means a single-source recording.
public enum RealtimeAudioChannel: String, Codable, Sendable, CaseIterable {
  /// The local microphone: always the user, labeled `RealtimeSpeaker.selfPersonID`.
  case microphone
  /// Audio played by the computer, such as the remote side of an online meeting.
  case system
}

public struct RealtimeSessionRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let recordingID: String
  public let language: String?
  public let audio: RealtimeAudioFormat
  /// Omitted on the wire for single-source recordings.
  public let channel: RealtimeAudioChannel?
  /// Off unless the user turned on telling speakers apart; nil is omitted on the wire.
  public let speakerDiarization: Bool?
  /// Saved voices the processor may recognize, identified only by opaque person IDs.
  public let knownVoiceprints: [RealtimeKnownVoiceprint]?

  public init(
    recordingID: String,
    language: String?,
    channel: RealtimeAudioChannel? = nil,
    speakerDiarization: Bool = false,
    knownVoiceprints: [RealtimeKnownVoiceprint] = []
  ) {
    protocolVersion = RealtimeProtocol.version
    self.recordingID = recordingID
    self.language = language
    audio = .realtime
    self.channel = channel
    self.speakerDiarization = speakerDiarization ? true : nil
    self.knownVoiceprints = speakerDiarization && !knownVoiceprints.isEmpty ? knownVoiceprints : nil
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case recordingID = "recording_id"
    case language
    case audio
    case channel
    case speakerDiarization = "speaker_diarization"
    case knownVoiceprints = "known_voiceprints"
  }
}

public struct RealtimeKnownVoiceprint: Codable, Equatable, Sendable {
  public let personID: String
  public let model: String
  public let embedding: [Double]

  public init(personID: String, voiceprint: RealtimeVoiceprint) {
    self.personID = personID
    model = voiceprint.model
    embedding = voiceprint.embedding
  }

  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case model
    case embedding
  }
}

/// A speaker embedding; it is meaningful only to the processor model that produced it.
public struct RealtimeVoiceprint: Codable, Equatable, Sendable {
  public let model: String
  public let embedding: [Double]

  public init(model: String, embedding: [Double]) {
    self.model = model
    self.embedding = embedding
  }
}

public struct RealtimeVoiceprintEnrollmentRequest: Codable, Equatable, Sendable {
  public static let recommendedDuration: TimeInterval = 20

  public let protocolVersion: Int
  public let audio: RealtimeAudioFormat
  public let audioBase64: String

  public init(pcm16LittleEndian: Data) {
    protocolVersion = RealtimeProtocol.version
    audio = .realtime
    audioBase64 = pcm16LittleEndian.base64EncodedString()
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case audio
    case audioBase64 = "audio_base64"
  }
}

public struct RealtimeVoiceprintEnrollmentResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let voiceprint: RealtimeVoiceprint
  public let speechMilliseconds: Int

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case voiceprint
    case speechMilliseconds = "speech_ms"
  }
}

public struct RealtimeVoiceprintEnrollmentFailure: Codable, Equatable, Sendable {
  public let error: String
}

public struct RealtimeAudioFormat: Codable, Equatable, Sendable {
  public static let realtime = RealtimeAudioFormat(
    encoding: RealtimeProtocol.encoding,
    sampleRate: RealtimeProtocol.sampleRate,
    channels: RealtimeProtocol.channels
  )

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
  /// Person ID of the device owner's own enrolled voice.
  public static let selfPersonID = "self"

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
  /// Set by the Gateway for sessions opened with a channel; segment IDs are unique per channel.
  public let channel: RealtimeAudioChannel?

  public var id: String { channel.map { "\($0.rawValue)/\(segmentID)" } ?? segmentID }

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
    speaker: RealtimeSpeaker?,
    channel: RealtimeAudioChannel? = nil
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
    self.channel = channel
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
    case channel
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
