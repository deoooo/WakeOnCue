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
    if state.usesS3 {
      HStack {
        Label(duration(state.uploadedDurationSeconds), systemImage: "icloud.and.arrow.up")
        Spacer()
        Label(duration(state.pendingDurationSeconds), systemImage: "clock.arrow.circlepath")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    } else {
      Label(AppLanguage.localized("Saved on this iPhone"), systemImage: "iphone")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func statusTitle(_ state: RecordingActivityAttributes.ContentState) -> String {
    switch state.phase {
    case "PAUSED": AppLanguage.localized("Recording paused")
    case "FINISHING", "UPLOADING":
      state.usesS3
        ? AppLanguage.localized("Syncing recording")
        : AppLanguage.localized("Saving recording")
    case "COMPLETED":
      state.usesS3
        ? AppLanguage.localized("Recording synced")
        : AppLanguage.localized("Recording saved")
    case "FAILED":
      state.usesS3
        ? AppLanguage.localized("Sync needs attention")
        : AppLanguage.localized("Recording needs attention")
    default: AppLanguage.localized("Recording")
    }
  }

  private func statusIcon(_ state: RecordingActivityAttributes.ContentState) -> String {
    switch state.phase {
    case "PAUSED": "pause.circle.fill"
    case "FINISHING", "UPLOADING": state.usesS3 ? "icloud.and.arrow.up.fill" : "externaldrive.fill"
    case "COMPLETED": state.usesS3 ? "checkmark.icloud.fill" : "checkmark.circle.fill"
    case "FAILED": state.usesS3 ? "exclamationmark.icloud.fill" : "exclamationmark.circle.fill"
    default: "record.circle"
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
