import ActivityKit
import Foundation

public struct RecordingActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, Sendable {
    public var phase: String
    public var usesS3: Bool
    public var timerStart: Date
    public var pausedElapsedSeconds: Int
    public var uploadedDurationSeconds: Int
    public var pendingDurationSeconds: Int

    public init(
      phase: String,
      usesS3: Bool = false,
      timerStart: Date,
      pausedElapsedSeconds: Int = 0,
      uploadedDurationSeconds: Int = 0,
      pendingDurationSeconds: Int = 0
    ) {
      self.phase = phase
      self.usesS3 = usesS3
      self.timerStart = timerStart
      self.pausedElapsedSeconds = pausedElapsedSeconds
      self.uploadedDurationSeconds = uploadedDurationSeconds
      self.pendingDurationSeconds = pendingDurationSeconds
    }

    private enum CodingKeys: String, CodingKey {
      case phase, usesS3, timerStart, pausedElapsedSeconds
      case uploadedDurationSeconds, pendingDurationSeconds
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      phase = try container.decode(String.self, forKey: .phase)
      usesS3 = try container.decodeIfPresent(Bool.self, forKey: .usesS3) ?? false
      timerStart = try container.decode(Date.self, forKey: .timerStart)
      pausedElapsedSeconds = try container.decode(Int.self, forKey: .pausedElapsedSeconds)
      uploadedDurationSeconds = try container.decode(Int.self, forKey: .uploadedDurationSeconds)
      pendingDurationSeconds = try container.decode(Int.self, forKey: .pendingDurationSeconds)
    }
  }

  public let recordingID: String

  public init(recordingID: String) {
    self.recordingID = recordingID
  }
}
