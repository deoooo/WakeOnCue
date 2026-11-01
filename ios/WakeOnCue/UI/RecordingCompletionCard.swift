import SwiftUI
import WakeOnCueCore

struct RecordingCompletionCard: View {
  @Environment(AppModel.self) private var model

  let recording: RecordingRecord
  let onDismiss: () -> Void

  @State private var displayedRecording: RecordingRecord
  @State private var isEditingTitle = false

  init(recording: RecordingRecord, onDismiss: @escaping () -> Void) {
    self.recording = recording
    self.onDismiss = onDismiss
    _displayedRecording = State(initialValue: recording)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: headlineSymbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(headlineColor)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(headline)
            .font(.headline)
          Text(displayedRecording.libraryDisplayTitle(language: language))
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
          Label(recordingDuration(displayedRecording.duration), systemImage: "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(language.localized("Dismiss"))
        .accessibilityIdentifier("recording-completion-dismiss")
      }

      storageStatus
      actions
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color(uiColor: .separator).opacity(0.45))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recording-completion-card")
    .sheet(isPresented: $isEditingTitle) {
      RecordingTitleEditor(recording: displayedRecording) { updated in
        displayedRecording = updated
        Task { await model.refresh() }
      }
      .environment(\.locale, language.locale)
      .presentationDetents([.medium])
    }
    .onChange(of: recording) { _, updated in
      displayedRecording = updated
    }
  }

  @ViewBuilder
  private var storageStatus: some View {
    let presentation = displayedRecording.storagePresentation
    if presentation.cloudBackup == .pending {
      VStack(alignment: .leading, spacing: 5) {
        statusLabel(
          presentation.localFileStatusText(language: language),
          systemImage: localFileSymbol(presentation.localFile),
          color: localFileColor(presentation.localFile)
        )
        statusLabel(
          presentation.cloudBackupStatusText(language: language)
            ?? displayedRecording.storageStatusText(language: language),
          systemImage: "icloud.and.arrow.up",
          color: .secondary
        )
      }
    } else {
      statusLabel(
        displayedRecording.storageStatusText(language: language),
        systemImage: localFileSymbol(presentation.localFile),
        color: localFileColor(presentation.localFile)
      )
    }
  }

  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { actionViews }
      VStack(alignment: .leading, spacing: 8) { actionViews }
    }
  }

  @ViewBuilder
  private var actionViews: some View {
    Button {
      isEditingTitle = true
    } label: {
      Label(language.localized("Rename"), systemImage: "pencil")
    }
    .buttonStyle(.bordered)
    .frame(minHeight: 44)
    .accessibilityIdentifier("recording-completion-rename")

    NavigationLink {
      RecordingDetailView(recording: displayedRecording)
    } label: {
      Label(language.localized("Review"), systemImage: "doc.text.magnifyingglass")
    }
    .buttonStyle(.bordered)
    .frame(minHeight: 44)
    .accessibilityIdentifier("recording-completion-review")

    Button {
      Task { await model.share(recording: displayedRecording) }
    } label: {
      Label(language.localized("Share"), systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.bordered)
    .frame(minHeight: 44)
    .accessibilityIdentifier("recording-completion-share")
  }

  private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
  }

  private var language: AppLanguage { model.settings.language }

  private var headline: String {
    switch displayedRecording.storagePresentation.localFile {
    case .saved:
      language.localized("Recording saved")
    case .notStarted, .saving, .unavailable, .unknown:
      language.localized("Recording finished")
    }
  }

  private var headlineSymbol: String {
    displayedRecording.storagePresentation.localFile == .saved
      ? "checkmark.circle.fill" : "waveform.circle.fill"
  }

  private var headlineColor: Color {
    switch displayedRecording.storagePresentation.localFile {
    case .saved: .green
    case .notStarted, .saving, .unknown: .secondary
    case .unavailable: .orange
    }
  }

  private func localFileSymbol(_ state: RecordingStatusPresentation.LocalFileState) -> String {
    switch state {
    case .notStarted: "iphone"
    case .saving: "arrow.down.circle"
    case .saved: "iphone"
    case .unavailable: "exclamationmark.triangle.fill"
    case .unknown: "questionmark.circle"
    }
  }

  private func localFileColor(_ state: RecordingStatusPresentation.LocalFileState) -> Color {
    switch state {
    case .saved: .green
    case .unavailable: .orange
    case .notStarted, .saving, .unknown: .secondary
    }
  }
}

private func recordingDuration(_ interval: TimeInterval) -> String {
  let seconds = max(0, Int(interval.rounded(.down)))
  if seconds >= 3_600 {
    return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
  }
  return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
