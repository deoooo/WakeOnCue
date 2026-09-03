import CoreFoundation
import Foundation

public enum RecordingCommand: String, Codable, Sendable {
  case start
  case pause
  case resume
  case finish
}

public struct SharedRecordingSnapshot: Codable, Sendable {
  public let isRecording: Bool
  public let isPaused: Bool
  public let recordingID: String?
  public let updatedAt: Date
}

public enum SharedRecordingState {
  public static let appGroup = "group.com.deoooo.WakeOnCue"
  public static let controlKind = "com.deoooo.WakeOnCue.recording-control"
  public static let commandNotification = "com.deoooo.WakeOnCue.recording-command"

  private static let commandKey = "recording.pending-command"
  private static let commandDateKey = "recording.pending-command-date"
  private static let isRecordingKey = "recording.is-recording"
  private static let isPausedKey = "recording.is-paused"
  private static let recordingIDKey = "recording.id"
  private static let updatedAtKey = "recording.updated-at"

  public static func enqueue(_ command: RecordingCommand) {
    let defaults = defaults()
    defaults.set(command.rawValue, forKey: commandKey)
    defaults.set(Date().timeIntervalSince1970, forKey: commandDateKey)
    defaults.synchronize()
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(commandNotification as CFString),
      nil,
      nil,
      true
    )
  }

  public static func consumePendingCommand(maximumAge: TimeInterval = 120) -> RecordingCommand? {
    let defaults = defaults()
    guard let rawValue = defaults.string(forKey: commandKey),
      let command = RecordingCommand(rawValue: rawValue)
    else { return nil }
    let createdAt = Date(timeIntervalSince1970: defaults.double(forKey: commandDateKey))
    defaults.removeObject(forKey: commandKey)
    defaults.removeObject(forKey: commandDateKey)
    guard Date().timeIntervalSince(createdAt) <= maximumAge else { return nil }
    return command
  }

  public static func update(
    isRecording: Bool,
    isPaused: Bool,
    recordingID: String?
  ) {
    let defaults = defaults()
    defaults.set(isRecording, forKey: isRecordingKey)
    defaults.set(isPaused, forKey: isPausedKey)
    defaults.set(recordingID, forKey: recordingIDKey)
    defaults.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
  }

  public static func snapshot() -> SharedRecordingSnapshot {
    let defaults = defaults()
    return SharedRecordingSnapshot(
      isRecording: defaults.bool(forKey: isRecordingKey),
      isPaused: defaults.bool(forKey: isPausedKey),
      recordingID: defaults.string(forKey: recordingIDKey),
      updatedAt: Date(timeIntervalSince1970: defaults.double(forKey: updatedAtKey))
    )
  }

  private static func defaults() -> UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }
}

public final class RecordingIntentDispatcher: @unchecked Sendable {
  public static let shared = RecordingIntentDispatcher()

  private let lock = NSLock()
  private var handler: (@Sendable (RecordingCommand) async -> Void)?

  private init() {}

  public func install(handler: @escaping @Sendable (RecordingCommand) async -> Void) {
    lock.withLock { self.handler = handler }
  }

  public func dispatch(_ command: RecordingCommand) async {
    let currentHandler = lock.withLock { handler }
    if let currentHandler {
      await currentHandler(command)
    } else {
      SharedRecordingState.enqueue(command)
    }
  }
}
