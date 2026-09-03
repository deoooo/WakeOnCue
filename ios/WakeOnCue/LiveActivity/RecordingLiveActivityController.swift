import ActivityKit
import Foundation
import WakeOnCueCore

@MainActor
final class RecordingLiveActivityController {
  func start(
    recording: RecordingRecord,
    progress: RecordingSyncProgress = .init(),
    usesS3: Bool = false
  ) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let existing = Activity<RecordingActivityAttributes>.activities
    for activity in existing where activity.attributes.recordingID.hasPrefix("pending_") {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    guard
      !Activity<RecordingActivityAttributes>.activities.contains(where: {
        $0.attributes.recordingID == recording.id
      })
    else { return }
    let state = contentState(recording: recording, progress: progress, usesS3: usesS3)
    _ = try? Activity.request(
      attributes: RecordingActivityAttributes(recordingID: recording.id),
      content: ActivityContent(
        state: state,
        staleDate: Date().addingTimeInterval(12 * 60 * 60)
      ),
      pushType: nil
    )
  }

  func update(
    recording: RecordingRecord,
    progress: RecordingSyncProgress,
    usesS3: Bool
  ) async {
    let state = contentState(recording: recording, progress: progress, usesS3: usesS3)
    let content = ActivityContent(
      state: state,
      staleDate: Date().addingTimeInterval(12 * 60 * 60)
    )
    for activity in Activity<RecordingActivityAttributes>.activities
    where activity.attributes.recordingID == recording.id {
      await activity.update(content)
    }
  }

  func end(recording: RecordingRecord, progress: RecordingSyncProgress, usesS3: Bool) async {
    let content = ActivityContent(
      state: contentState(recording: recording, progress: progress, usesS3: usesS3),
      staleDate: nil
    )
    for activity in Activity<RecordingActivityAttributes>.activities
    where activity.attributes.recordingID == recording.id {
      await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
    }
  }

  func removeStaleActivities(activeRecordingID: String?) async {
    for activity in Activity<RecordingActivityAttributes>.activities
    where activity.attributes.recordingID != activeRecordingID {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }

  private func contentState(
    recording: RecordingRecord,
    progress: RecordingSyncProgress,
    usesS3: Bool
  ) -> RecordingActivityAttributes.ContentState {
    let elapsed = max(0, Int(recording.duration.rounded(.down)))
    return RecordingActivityAttributes.ContentState(
      phase: recording.status.rawValue,
      usesS3: usesS3,
      timerStart: Date().addingTimeInterval(-recording.duration),
      pausedElapsedSeconds: elapsed,
      uploadedDurationSeconds: Int(progress.uploadedDuration.rounded()),
      pendingDurationSeconds: Int(progress.pendingDuration.rounded())
    )
  }
}
