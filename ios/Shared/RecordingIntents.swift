import ActivityKit
import AppIntents
import Foundation

public struct StartRecordingIntent: AudioRecordingIntent {
  public static let title: LocalizedStringResource = "Start Meeting Recording"
  public static let description = IntentDescription("Start a reliable local meeting recording.")
  public static let openAppWhenRun = true

  @available(iOS 26.0, *)
  public static var supportedModes: IntentModes { [.foreground(.immediate)] }

  public init() {}

  public func perform() async throws -> some IntentResult {
    await RecordingIntentActivity.ensureStarted()
    await RecordingIntentDispatcher.shared.dispatch(.start)
    return .result()
  }
}

public struct PauseRecordingIntent: AudioRecordingIntent {
  public static let title: LocalizedStringResource = "Pause Meeting Recording"

  public init() {}

  public func perform() async throws -> some IntentResult {
    await RecordingIntentDispatcher.shared.dispatch(.pause)
    return .result()
  }
}

public struct ResumeRecordingIntent: AudioRecordingIntent {
  public static let title: LocalizedStringResource = "Resume Meeting Recording"

  public init() {}

  public func perform() async throws -> some IntentResult {
    await RecordingIntentDispatcher.shared.dispatch(.resume)
    return .result()
  }
}

public struct FinishRecordingIntent: AudioRecordingIntent {
  public static let title: LocalizedStringResource = "Finish Meeting Recording"

  public init() {}

  public func perform() async throws -> some IntentResult {
    await RecordingIntentDispatcher.shared.dispatch(.finish)
    return .result()
  }
}

public struct ToggleRecordingIntent: AudioRecordingIntent {
  public static let title: LocalizedStringResource = "Start or Finish Recording"
  public static let description = IntentDescription(
    "Start a meeting recording, or finish the active recording.")
  public static let openAppWhenRun = true

  @available(iOS 26.0, *)
  public static var supportedModes: IntentModes { [.foreground(.immediate)] }

  public init() {}

  public func perform() async throws -> some IntentResult {
    if SharedRecordingState.snapshot().isRecording {
      await RecordingIntentDispatcher.shared.dispatch(.finish)
    } else {
      await RecordingIntentActivity.ensureStarted()
      await RecordingIntentDispatcher.shared.dispatch(.start)
    }
    return .result()
  }
}

private enum RecordingIntentActivity {
  static func ensureStarted() async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled,
      Activity<RecordingActivityAttributes>.activities.isEmpty
    else { return }
    let now = Date()
    let temporaryID = "pending_\(UUID().uuidString.lowercased())"
    let state = RecordingActivityAttributes.ContentState(
      phase: "RECORDING",
      timerStart: now
    )
    let content = ActivityContent(
      state: state,
      staleDate: now.addingTimeInterval(12 * 60 * 60)
    )
    _ = try? Activity.request(
      attributes: RecordingActivityAttributes(recordingID: temporaryID),
      content: content,
      pushType: nil
    )
  }
}
