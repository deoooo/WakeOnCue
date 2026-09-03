import SwiftUI
import WidgetKit

struct RecordingControlWidget: ControlWidget {
  static let kind = SharedRecordingState.controlKind

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isRecording in
      ControlWidgetButton(action: ToggleRecordingIntent()) {
        Label(
          isRecording
            ? AppLanguage.localized("Finish Recording")
            : AppLanguage.localized("Start Recording"),
          systemImage: isRecording ? "stop.fill" : "record.circle"
        )
      }
    }
    .displayName("Meeting Recording")
    .description("Start or finish a WakeOnCue meeting recording.")
  }
}

extension RecordingControlWidget {
  fileprivate struct Provider: ControlValueProvider {
    let previewValue = false

    func currentValue() async throws -> Bool {
      SharedRecordingState.snapshot().isRecording
    }
  }
}
