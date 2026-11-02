import Foundation

/// Message contract shared by the iPhone app, the Watch app, and the Watch complications.
/// Every payload travels as one JSON `Data` value under a single key so both sides can
/// evolve the Codable types without juggling WatchConnectivity property-list rules.
public enum WatchBridgeKey {
  public static let request = "request"
  public static let reply = "reply"
  public static let snapshot = "snapshot"
  public static let segment = "segment"
  public static let session = "session"
}

public enum WatchRecordingPhase: String, Codable, Sendable {
  case idle
  case recording
  case paused
  case finishing
}

/// The iPhone recording state as the Watch sees it. `elapsed` is measured at `capturedAt`,
/// so the Watch can keep a running clock without a message every second.
public struct WatchRecordingSnapshot: Codable, Equatable, Sendable {
  public var phase: WatchRecordingPhase
  public var recordingID: String?
  public var elapsed: TimeInterval
  public var capturedAt: Date
  /// Duration of recordings that started today and are no longer active.
  public var todayCompletedDuration: TimeInterval

  public init(
    phase: WatchRecordingPhase,
    recordingID: String? = nil,
    elapsed: TimeInterval = 0,
    capturedAt: Date = Date(),
    todayCompletedDuration: TimeInterval = 0
  ) {
    self.phase = phase
    self.recordingID = recordingID
    self.elapsed = max(0, elapsed)
    self.capturedAt = capturedAt
    self.todayCompletedDuration = max(0, todayCompletedDuration)
  }

  public static let idle = WatchRecordingSnapshot(phase: .idle, capturedAt: .distantPast)

  public var isActive: Bool { phase == .recording || phase == .paused }

  public func elapsed(at now: Date) -> TimeInterval {
    guard phase == .recording else { return elapsed }
    return elapsed + max(0, now.timeIntervalSince(capturedAt))
  }

  /// The wall-clock start that makes `Text(timerInterval:)` show the live elapsed time.
  public var timerStart: Date { capturedAt.addingTimeInterval(-elapsed) }

  public func todayDuration(at now: Date) -> TimeInterval {
    todayCompletedDuration + (isActive ? elapsed(at: now) : 0)
  }

  /// Two snapshots that would render identically do not need another transfer.
  public func isEquivalent(to other: WatchRecordingSnapshot, tolerance: TimeInterval = 2) -> Bool {
    guard phase == other.phase, recordingID == other.recordingID,
      abs(todayCompletedDuration - other.todayCompletedDuration) < tolerance
    else { return false }
    if phase == .recording {
      return abs(timerStart.timeIntervalSince(other.timerStart)) < tolerance
    }
    return abs(elapsed - other.elapsed) < tolerance
  }
}

/// Optional labels the Watch offers after "Save that".
public enum RecordingMarkTag: String, Codable, CaseIterable, Sendable {
  case todo
  case important
  case idea
}

public enum WatchBridgeRequest: Codable, Equatable, Sendable {
  case snapshot
  case start
  case pause
  case resume
  case finish
  case bookmark
  /// Marks the last `seconds` of the active iPhone recording.
  case markRecent(seconds: TimeInterval)
  case tagBookmark(recordingID: String, bookmarkID: UUID, tag: RecordingMarkTag?)
}

public enum WatchBridgeFailure: Codable, Equatable, Sendable {
  case notRecording
  case busy
  case failed(String)
}

public struct WatchMarkResult: Codable, Equatable, Sendable {
  public let recordingID: String
  public let bookmarkID: UUID
  public let savedSeconds: TimeInterval

  public init(recordingID: String, bookmarkID: UUID, savedSeconds: TimeInterval) {
    self.recordingID = recordingID
    self.bookmarkID = bookmarkID
    self.savedSeconds = savedSeconds
  }
}

public struct WatchBridgeReply: Codable, Equatable, Sendable {
  public var failure: WatchBridgeFailure?
  public var snapshot: WatchRecordingSnapshot?
  public var mark: WatchMarkResult?

  public init(
    failure: WatchBridgeFailure? = nil,
    snapshot: WatchRecordingSnapshot? = nil,
    mark: WatchMarkResult? = nil
  ) {
    self.failure = failure
    self.snapshot = snapshot
    self.mark = mark
  }

  public var succeeded: Bool { failure == nil }
}

/// One fixed-length piece of a recording made on the Watch. Pieces travel independently, so a
/// long recording reaches the iPhone progressively and a lost connection costs nothing.
public struct WatchSegmentMetadata: Codable, Equatable, Sendable {
  public let sessionID: UUID
  /// 1-based position of the piece inside its recording.
  public let index: Int
  public let startedAt: Date
  public let duration: TimeInterval

  public init(sessionID: UUID, index: Int, startedAt: Date, duration: TimeInterval) {
    self.sessionID = sessionID
    self.index = index
    self.startedAt = startedAt
    self.duration = max(0, duration)
  }

  public var fileName: String { String(format: "segment-%04d.m4a", index) }
}

public struct WatchSessionBookmark: Codable, Equatable, Sendable {
  public let id: UUID
  public let position: TimeInterval
  public var duration: TimeInterval?
  public var tag: RecordingMarkTag?

  public init(
    id: UUID = UUID(),
    position: TimeInterval,
    duration: TimeInterval? = nil,
    tag: RecordingMarkTag? = nil
  ) {
    self.id = id
    self.position = max(0, position)
    self.duration = duration.map { max(0, $0) }
    self.tag = tag
  }
}

/// Sent once a Watch recording ends; the iPhone assembles the recording when every piece is in.
public struct WatchSessionSummary: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let startedAt: Date
  public var endedAt: Date
  public var segmentCount: Int
  public var bookmarks: [WatchSessionBookmark]
  /// Why the recording ended: "user", "interruption", "write_failure", or "recovered" after the
  /// app was stopped.
  public var endReason: String

  public init(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    segmentCount: Int,
    bookmarks: [WatchSessionBookmark] = [],
    endReason: String = "user"
  ) {
    self.sessionID = sessionID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.segmentCount = max(0, segmentCount)
    self.bookmarks = bookmarks
    self.endReason = endReason
  }

  public var recordingID: String {
    "rec_watchrec_\(sessionID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
  }
}

public enum WatchBridgeCoding {
  public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(value)
  }

  public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(type, from: data)
  }

  public static func message<Value: Encodable>(_ key: String, _ value: Value) throws -> [String: Any] {
    [key: try encode(value)]
  }

  public static func value<Value: Decodable>(
    _ type: Value.Type,
    key: String,
    in dictionary: [String: Any]
  ) -> Value? {
    guard let data = dictionary[key] as? Data else { return nil }
    return try? decode(type, from: data)
  }
}
