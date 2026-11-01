import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecordingLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Circle()
            .fill(statusColor(context.state.phase))
            .frame(width: 10, height: 10)
          Text(statusTitle(context.state))
            .font(.headline)
          Spacer()
          elapsedView(context.state)
            .monospacedDigit()
            .font(.title3.weight(.semibold))
        }
        storageStatus(context.state)
        if ["RECORDING", "PAUSED"].contains(context.state.phase) {
          HStack {
            if context.state.phase == "PAUSED" {
              Button(intent: ResumeRecordingIntent()) {
                Label(AppLanguage.localized("Resume"), systemImage: "play.fill")
              }
            } else {
              Button(intent: PauseRecordingIntent()) {
                Label(AppLanguage.localized("Pause"), systemImage: "pause.fill")
              }
            }
            Spacer()
            Button(intent: FinishRecordingIntent()) {
              Label(AppLanguage.localized("Finish"), systemImage: "stop.fill")
            }
            .tint(.red)
          }
          .buttonStyle(.bordered)
        }
      }
      .padding()
      .activityBackgroundTint(Color.black.opacity(0.9))
      .activitySystemActionForegroundColor(.white)
      .environment(\.locale, AppLanguage.current.locale)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(statusTitle(context.state), systemImage: statusIcon(context.state))
            .foregroundStyle(statusColor(context.state.phase))
        }
        DynamicIslandExpandedRegion(.trailing) {
          elapsedView(context.state)
            .monospacedDigit()
        }
        DynamicIslandExpandedRegion(.bottom) {
          storageStatus(context.state)
        }
      } compactLeading: {
        Image(systemName: statusIcon(context.state))
          .foregroundStyle(statusColor(context.state.phase))
      } compactTrailing: {
        elapsedView(context.state)
          .monospacedDigit()
          .frame(maxWidth: 52)
      } minimal: {
        Image(systemName: "record.circle")
          .foregroundStyle(.red)
      }
      .keylineTint(.red)
    }
  }

  @ViewBuilder
  private func elapsedView(_ state: RecordingActivityAttributes.ContentState) -> some View {
    if state.phase == "RECORDING" {
      Text(state.timerStart, style: .timer)
    } else {
      Text(duration(state.pausedElapsedSeconds))
    }
  }

  @ViewBuilder
  private func storageStatus(_ state: RecordingActivityAttributes.ContentState) -> some View {
    let presentation = presentation(state)
    VStack(alignment: .leading, spacing: 4) {
      Label(localFileTitle(presentation.localFile), systemImage: localFileIcon(presentation.localFile))
      if state.usesS3 {
        HStack {
          Label(cloudBackupTitle(presentation.cloudBackup), systemImage: "icloud.and.arrow.up")
          Spacer()
          if presentation.cloudBackup == .pending {
            Text(duration(state.pendingDurationSeconds))
              .monospacedDigit()
          }
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private func statusTitle(_ state: RecordingActivityAttributes.ContentState) -> String {
    switch presentation(state).capture {
    case .ready: AppLanguage.localized("Ready")
    case .recording: AppLanguage.localized("Recording")
    case .paused: AppLanguage.localized("Recording paused")
    case .finishing: AppLanguage.localized("Finishing recording")
    case .finalized: AppLanguage.localized("Recording finished")
    case .failed: AppLanguage.localized("Recording needs attention")
    }
  }

  private func statusIcon(_ state: RecordingActivityAttributes.ContentState) -> String {
    switch presentation(state).capture {
    case .ready, .recording: "record.circle"
    case .paused: "pause.circle.fill"
    case .finishing: "externaldrive.fill"
    case .finalized: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  private func presentation(_ state: RecordingActivityAttributes.ContentState)
    -> RecordingStatusPresentation
  {
    RecordingStatusPresentation.classifyActivity(
      phase: state.phase,
      cloudWasConfigured: state.usesS3
    )
  }

  private func localFileTitle(_ state: RecordingStatusPresentation.LocalFileState) -> String {
    switch state {
    case .notStarted: AppLanguage.localized("Recordings save on this iPhone")
    case .saving: AppLanguage.localized("Saving on this iPhone")
    case .saved: AppLanguage.localized("Saved on this iPhone")
    case .unavailable: AppLanguage.localized("Not available on this iPhone")
    case .unknown: AppLanguage.localized("Local file status unknown")
    }
  }

  private func localFileIcon(_ state: RecordingStatusPresentation.LocalFileState) -> String {
    switch state {
    case .notStarted, .saving, .saved: "iphone"
    case .unavailable: "iphone.slash"
    case .unknown: "questionmark.circle"
    }
  }

  private func cloudBackupTitle(_ state: RecordingStatusPresentation.CloudBackupState) -> String {
    switch state {
    case .notRequested: AppLanguage.localized("Cloud backup off")
    case .pending: AppLanguage.localized("Backup pending")
    case .synced: AppLanguage.localized("Backup complete")
    case .failed: AppLanguage.localized("Backup needs attention")
    case .abandoned: AppLanguage.localized("Cloud backup skipped")
    }
  }

  private func statusColor(_ phase: String) -> Color {
    switch phase {
    case "PAUSED": .orange
    case "FINISHING", "UPLOADING": .blue
    case "COMPLETED": .green
    case "FAILED": .red
    default: .red
    }
  }

  private func duration(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = seconds % 3_600 / 60
    let seconds = seconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
  }

}
