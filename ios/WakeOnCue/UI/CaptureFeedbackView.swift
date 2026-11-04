import SwiftUI

/// Reads the meter itself, so its ten updates a second redraw only this view and not the home screen.
struct LiveCaptureFeedbackView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    CaptureFeedbackView(feedback: model.captureFeedback) {
      Task { await model.resumeRecording() }
    }
  }
}

struct CaptureFeedbackView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let feedback: RecordingCaptureFeedback
  let onResume: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(statusTitle)
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier(statusAccessibilityIdentifier)
          if let inputSourceName = feedback.inputSourceName {
            Text(
              String(
                format: AppLanguage.localized("Input: %@"),
                inputSourceName
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("capture-input-route")
          }
        }
        Spacer()
        if feedback.pauseReason != nil {
          Button(AppLanguage.localized("Resume recording"), action: onResume)
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
      }

      if feedback.hasSustainedSilence, feedback.pauseReason == nil {
        Text(AppLanguage.localized("Check the microphone or move closer."))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("capture-silence-advice")
      }

      GeometryReader { proxy in
        Capsule()
          .fill(Color.secondary.opacity(0.18))
          .overlay(alignment: .leading) {
            Capsule()
              .fill(statusColor)
              .frame(width: proxy.size.width * CGFloat(feedback.normalizedInputLevel))
              .animation(
                reduceMotion ? nil : .linear(duration: RecordingCaptureMeter.updateInterval),
                value: feedback.normalizedInputLevel
              )
          }
      }
      .frame(height: 6)
      .accessibilityLabel(AppLanguage.localized("Microphone input level"))
      .accessibilityValue(
        String(format: "%d%%", Int(feedback.normalizedInputLevel * 100))
      )
      .accessibilityIdentifier("capture-input-level")
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("capture-feedback")
  }

  private var statusTitle: String {
    if feedback.pauseReason == .systemInterruption {
      return AppLanguage.localized("Recording was interrupted by the system.")
    }
    if feedback.pauseReason == .userPaused {
      return AppLanguage.localized("Recording paused.")
    }
    if feedback.hasSustainedSilence {
      return AppLanguage.localized("No sound detected.")
    }
    return AppLanguage.localized("Microphone is active.")
  }

  private var statusSymbol: String {
    if feedback.pauseReason == .systemInterruption { return "exclamationmark.triangle.fill" }
    if feedback.pauseReason == .userPaused { return "pause.circle.fill" }
    if feedback.hasSustainedSilence { return "mic.slash.fill" }
    return "waveform"
  }

  private var statusAccessibilityIdentifier: String {
    if feedback.pauseReason == .systemInterruption { return "capture-interruption" }
    if feedback.hasSustainedSilence { return "capture-silence-warning" }
    return "capture-status"
  }

  private var statusColor: Color {
    if feedback.pauseReason == .systemInterruption || feedback.hasSustainedSilence {
      return .orange
    }
    if feedback.pauseReason == .userPaused { return .secondary }
    return .green
  }
}
