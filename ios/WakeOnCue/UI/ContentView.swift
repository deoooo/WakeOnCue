import AVFoundation
import SwiftUI
import UIKit
import WakeOnCueCore

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var dismissedRecordingID: String?

  private let accent = Color(red: 1.0, green: 0.25, blue: 0.34)
  private let canvas = Color(uiColor: .systemGroupedBackground)
  private let panel = Color(uiColor: .secondarySystemGroupedBackground)
  private let border = Color(uiColor: .separator).opacity(0.55)

  private var isCaptureActive: Bool {
    guard let status = model.currentRecording?.status else { return false }
    return status == .recording || status == .paused
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      ZStack {
        background
        ScrollView(showsIndicators: false) {
          VStack(spacing: 22) {
            header
            if model.microphonePermission != .granted {
              permissionBanner
            }
            if isCaptureActive {
              activeRecorderPanel
              allRecordingsLink
            } else {
              recorderPanel
              if let finished = model.lastFinishedRecording, dismissedRecordingID != finished.id {
                RecordingCompletionCard(recording: finished) {
                  dismissedRecordingID = finished.id
                }
                .id(finished.id)
              }
              recentRecordings
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 10)
          .padding(.bottom, 36)
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if isCaptureActive {
          persistentRecordingControls
        }
      }
      .sheet(isPresented: $model.settingsPresented) {
        SettingsView()
          .environment(model)
      }
      .sheet(item: $model.shareItem) { item in
        RecordingShareSheet(fileURL: item.url)
      }
    }
    // Outside the stack, so errors also show while a recording's details are open.
    .alert(
      "WakeOnCue",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .environment(\.locale, model.settings.language.locale)
  }

  private var background: some View {
    ZStack {
      canvas.ignoresSafeArea()
      RadialGradient(
        colors: [accent.opacity(0.16), .clear],
        center: .topTrailing,
        startRadius: 10,
        endRadius: 360
      )
      .ignoresSafeArea()
    }
  }

  private var header: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            brandTitle
            Spacer(minLength: 12)
            settingsButton
          }
          brandSubtitle
        }
      } else {
        standardHeader
      }
    }
  }

  private var brandTitle: some View {
    Text("WakeOnCue")
      .font(.title3.weight(.bold))
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }

  private var brandSubtitle: some View {
    Text("Never miss a meeting")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var standardHeader: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(accent.opacity(0.16))
        Image(systemName: "waveform")
          .font(.headline.weight(.bold))
          .foregroundStyle(accent)
      }
      .frame(width: 42, height: 42)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        brandTitle
        brandSubtitle
      }

      Spacer()

      settingsButton
    }
  }

  private var settingsButton: some View {
    Button {
        model.settingsPresented = true
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.body.weight(.semibold))
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .frame(minWidth: 44, minHeight: 44)
          .background(panel, in: Circle())
          .overlay(Circle().stroke(border))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
  }

  private var permissionBanner: some View {
    HStack(spacing: 13) {
      Image(systemName: "mic.badge.plus")
        .font(.title3.weight(.semibold))
        .foregroundStyle(accent)
        .frame(width: 40, height: 40)
        .background(accent.opacity(0.13), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text("Microphone access")
          .font(.subheadline.weight(.semibold))
        Text("Audio always saves locally first.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 4)

      Button(
        model.microphonePermission == .denied
          ? model.settings.language.localized("Settings")
          : model.settings.language.localized("Allow")
      ) {
        if model.microphonePermission == .denied {
          model.openSystemSettings()
        } else {
          Task { _ = await model.requestMicrophonePermission() }
        }
      }
      .font(.subheadline.weight(.semibold))
      .buttonStyle(.bordered)
      .tint(accent)
    }
    .padding(14)
    .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(border))
  }

  private var recorderPanel: some View {
    VStack(spacing: 0) {
      statusPill
        .padding(.top, 25)

      Text(duration(model.elapsed))
        .font(.system(.largeTitle, design: .rounded, weight: .medium))
        .monospacedDigit()
        .minimumScaleFactor(0.7)
        .padding(.top, 16)

      if let recordingSubtitle {
        Text(recordingSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      }

      controls
        .padding(.vertical, 28)

      Divider()
        .overlay(border)
        .padding(.horizontal, 20)
      localStorageIndicator
        .padding(16)
    }
    .frame(maxWidth: .infinity)
    .background(
      panel,
      in: RoundedRectangle(cornerRadius: 30, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .stroke(border)
    )
    .shadow(color: Color.primary.opacity(0.12), radius: 26, y: 16)
    .accessibilityElement(children: .contain)
  }

  private var activeRecorderPanel: some View {
    VStack(spacing: 18) {
      statusPill

      Text(duration(model.elapsed))
        .font(.system(.largeTitle, design: .rounded, weight: .medium))
        .monospacedDigit()
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("Elapsed recording time")

      if let recordingSubtitle {
        Text(recordingSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      LiveCaptureFeedbackView()

      if let current = model.currentRecording {
        ViewThatFits(in: .horizontal) {
          HStack {
            BookmarkButton(recordingID: current.id, position: model.elapsed)
              .buttonStyle(.bordered)
              .frame(minHeight: 44)
            Spacer()
            localStorageCompactStatus
          }
          VStack(alignment: .leading, spacing: 10) {
            BookmarkButton(recordingID: current.id, position: model.elapsed)
              .buttonStyle(.bordered)
              .frame(minHeight: 44)
            localStorageCompactStatus
          }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 24, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color(uiColor: .separator).opacity(0.5))
    )
    .accessibilityElement(children: .contain)
  }

  private var localStorageCompactStatus: some View {
    let presentation = model.currentRecording.map { recordingStatusPresentation(for: $0) }
    return Label(
      localStorageTitle(presentation?.localFile ?? .notStarted),
      systemImage: localStorageIcon(presentation?.localFile ?? .notStarted)
    )
    .font(.caption.weight(.semibold))
    .foregroundStyle(localStorageColor(presentation?.localFile ?? .notStarted))
    .accessibilityElement(children: .combine)
  }

  private var statusPill: some View {
    let status = model.currentRecording?.status ?? .ready
    return HStack(spacing: 8) {
      Circle()
        .fill(statusColor(status))
        .frame(width: 8, height: 8)
        .shadow(color: statusColor(status).opacity(0.8), radius: 5)
      Text(statusTitle(status).uppercased())
        .font(.caption2.weight(.bold))
        .tracking(1.4)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 8)
    .background(statusColor(status).opacity(0.12), in: Capsule())
    .foregroundStyle(statusColor(status))
    .accessibilityLabel("Recording status: \(statusTitle(status))")
    .accessibilityIdentifier("recording-status")
  }

  @ViewBuilder
  private var controls: some View {
    switch model.currentRecording?.status {
    case .recording, .paused:
      EmptyView()
    case .finishing, .uploading:
      VStack(spacing: 12) {
        ProgressView()
          .controlSize(.large)
          .tint(.cyan)
        Text(model.settings.language.localized("Finishing your local recording"))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        Button {
          Task { await model.finishLocally() }
        } label: {
          Label("Save to this iPhone", systemImage: "iphone.and.arrow.forward")
        }
        .buttonStyle(.bordered)
        .tint(.cyan)
        .disabled(model.isBusy)
        .accessibilityHint("Keeps this recording on this iPhone")
      }
      .frame(minHeight: 142)
    default:
      Button {
        Task { await model.startRecording() }
      } label: {
        VStack(spacing: 12) {
          ZStack {
            Circle()
              .fill(accent.opacity(0.14))
              .frame(width: 152, height: 152)
            Circle()
              .stroke(accent.opacity(0.28), lineWidth: 1)
              .frame(width: 136, height: 136)
            Circle()
              .fill(
                LinearGradient(
                  colors: [Color(red: 1, green: 0.36, blue: 0.4), accent],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .frame(width: 112, height: 112)
              .shadow(color: accent.opacity(0.38), radius: 22, y: 10)
            Image(systemName: "mic.fill")
              .font(.largeTitle.weight(.semibold))
              .foregroundStyle(.white)
          }
          Text("Start recording")
            .font(.headline)
            .foregroundStyle(.primary)
        }
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.isBusy || model.microphonePermission == .denied)
      .accessibilityLabel("Start meeting recording")
      .accessibilityIdentifier("start-recording")
    }
  }

  @ViewBuilder
  private var persistentRecordingControls: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(spacing: 10) { persistentRecordingActions }
      } else {
        HStack(spacing: 12) { persistentRecordingActions }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  @ViewBuilder
  private var persistentRecordingActions: some View {
      switch model.currentRecording?.status {
      case .recording:
        persistentAction(
          model.settings.language.localized("Pause"),
          icon: "pause.fill",
          color: .orange
        ) {
          await model.pauseRecording()
        }
      case .paused:
        persistentAction(
          model.settings.language.localized("Resume"),
          icon: "play.fill",
          color: .green
        ) {
          await model.resumeRecording()
        }
      default:
        EmptyView()
      }

      persistentAction(
        model.settings.language.localized("Finish"),
        icon: "stop.fill",
        color: accent
      ) {
        await model.finishRecording()
      }
      .accessibilityIdentifier("finish-recording")
  }

  private func persistentAction(
    _ title: String,
    icon: String,
    color: Color,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Label(title, systemImage: icon)
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(.borderedProminent)
    .tint(color)
    .disabled(model.isBusy)
  }

  private var allRecordingsLink: some View {
    NavigationLink {
      RecordingLibraryView()
        .environment(model)
    } label: {
      Label("All recordings", systemImage: "waveform.badge.magnifyingglass")
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("all-recordings")
  }

  private var recentRecordings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent recordings")
          .font(.headline)
        Spacer()
        NavigationLink {
          AskRecordingsView()
            .environment(model)
        } label: {
          Label("Ask", systemImage: "text.bubble")
        }
          .font(.caption)
          .accessibilityIdentifier("ask-recordings-home")
        NavigationLink {
          RecordingLibraryView()
            .environment(model)
        } label: {
          Text("All recordings")
        }
          .font(.caption)
          .accessibilityIdentifier("all-recordings")
      }

      if model.recentRecordings.isEmpty {
        HStack(spacing: 13) {
          Image(systemName: "waveform.badge.plus")
            .font(.title3)
            .foregroundStyle(accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("No recordings yet")
              .font(.subheadline.weight(.semibold))
            Text("Your completed and pending meetings appear here.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      } else {
        LazyVStack(spacing: 9) {
          ForEach(model.recentRecordings.prefix(8)) { recording in
            recordingRow(recording)
          }
        }
      }
    }
  }

  private func recordingRow(_ recording: RecordingRecord) -> some View {
    let progress = model.recentSyncProgress[recording.id] ?? .init()
    let presentation = recordingStatusPresentation(for: recording)
    let audioAvailable = [.uploading, .completed, .failed].contains(recording.status)
    return HStack(spacing: 13) {
      NavigationLink {
        RecordingDetailView(recording: recording)
          .environment(model)
      } label: {
        HStack(spacing: 13) {
          Image(systemName: recordingIcon(presentation))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(recordingColor(presentation))
            .frame(width: 38, height: 38)
            .background(
              recordingColor(presentation).opacity(0.12),
              in: Circle()
            )
          VStack(alignment: .leading, spacing: 3) {
            Text(recording.libraryDisplayTitle(language: model.settings.language))
              .font(.subheadline.weight(.semibold))
            Text("\(duration(recording.duration)) · \(recordingRowStatus(recording, presentation))")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let overview = recording.overview {
              Text(overview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 6)
          if presentation.cloudBackup == .pending && progress.pendingDuration > 0.5 {
            Text("\(shortDuration(progress.pendingDuration)) waiting")
              .font(.caption.monospacedDigit().weight(.semibold))
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(.orange.opacity(0.14), in: Capsule())
              .foregroundStyle(.orange)
          }
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "\(recording.libraryDisplayTitle(language: model.settings.language)), \(recordingRowStatus(recording, presentation))"
      )
      .accessibilityIdentifier("recording-details-\(recording.id)")

      if audioAvailable {
        Button {
          Task { await model.togglePlayback(for: recording) }
        } label: {
          if model.audioBusyRecordingID == recording.id {
            ProgressView().controlSize(.small)
          } else {
            Image(
              systemName:
                model.playingRecordingID == recording.id && model.playbackIsPlaying
                ? "pause.fill" : "play.fill"
            )
          }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(
          model.playingRecordingID == recording.id && model.playbackIsPlaying
            ? model.settings.language.localized("Pause recording")
            : model.settings.language.localized("Play recording"))

        Button {
          Task { await model.share(recording: recording) }
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Share audio file")
      }
    }
    .padding(14)
    .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(border))
    .contextMenu {
      if recording.canBeDeleted {
        Button(role: .destructive) {
          Task { await model.moveToTrash(recording) }
        } label: {
          Label("Delete recording", systemImage: "trash")
        }
      }
    }
  }

  private func recordingRowStatus(
    _ recording: RecordingRecord, _ presentation: RecordingStatusPresentation
  ) -> String {
    model.onDeviceProcessingRecordingIDs.contains(recording.id)
      ? model.settings.language.localized("Transcribing and summarizing…")
      : recordingStateLabel(presentation)
  }

  private var localStorageIndicator: some View {
    let presentation = model.currentRecording.map { recordingStatusPresentation(for: $0) }
    return HStack(spacing: 12) {
      Image(systemName: localStorageIcon(presentation?.localFile ?? .notStarted))
        .font(.headline.weight(.semibold))
        .foregroundStyle(localStorageColor(presentation?.localFile ?? .notStarted))
        .frame(width: 38, height: 38)
        .background(
          localStorageColor(presentation?.localFile ?? .notStarted).opacity(0.12), in: Circle()
        )
      VStack(alignment: .leading, spacing: 2) {
        Text(localStorageTitle(presentation?.localFile ?? .notStarted))
          .font(.subheadline.weight(.semibold))
        Text(storageCaption(presentation))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if presentation?.localFile == .saved {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityHidden(true)
      }
    }
    .padding(12)
    .background(
      Color(uiColor: .tertiarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .accessibilityElement(children: .combine)
  }

  private var recordingSubtitle: String? {
    guard let recording = model.currentRecording else {
      return model.settings.language.localized("Tap once when your meeting begins")
    }
    let presentation = recordingStatusPresentation(for: recording)
    return switch presentation.capture {
    case .recording: model.settings.language.localized("Saving on this iPhone")
    case .paused: model.settings.language.localized("Paused · recording remains on this iPhone")
    case .finishing: model.settings.language.localized("Finishing the recording on this iPhone")
    case .finalized: recordingStateLabel(presentation)
    case .failed: recordingStateLabel(presentation)
    case .ready: model.settings.language.localized("Tap once when your meeting begins")
    }
  }

  private func statusColor(_ status: RecordingStatus) -> Color {
    switch status {
    case .recording: accent
    case .paused: .orange
    case .finishing, .uploading: .cyan
    case .completed: .green
    case .failed: .red
    case .ready: .secondary
    }
  }

  private func statusTitle(_ status: RecordingStatus) -> String {
    let presentation = model.currentRecording.map { recordingStatusPresentation(for: $0) }
    return switch presentation?.capture {
    case .recording: model.settings.language.localized("Recording")
    case .paused: model.settings.language.localized("Paused")
    case .finishing: model.settings.language.localized("Finishing")
    case .finalized: model.settings.language.localized("Finished")
    case .failed: model.settings.language.localized("Needs attention")
    case .ready, nil: model.settings.language.localized("Ready")
    }
  }

  private func recordingStateLabel(_ presentation: RecordingStatusPresentation) -> String {
    presentation.storageStatusText(language: model.settings.language)
  }

  private func recordingStatusPresentation(for recording: RecordingRecord)
    -> RecordingStatusPresentation
  {
    recording.storagePresentation
  }

  private func localStorageTitle(_ state: RecordingStatusPresentation.LocalFileState) -> String {
    RecordingStatusPresentation(
      capture: .ready,
      localFile: state,
      cloudBackup: .notRequested,
      transcription: .notRequested
    ).localFileStatusText(language: model.settings.language)
  }

  private func storageCaption(_ presentation: RecordingStatusPresentation?) -> String {
    guard let presentation else {
      return model.settings.language.localized("No account or network needed")
    }
    return switch presentation.cloudBackup {
    case .notRequested: model.settings.language.localized("Saved on this iPhone")
    case .pending: model.settings.language.localized("Cloud backup pending")
    case .synced: model.settings.language.localized("Cloud backup complete")
    case .failed: model.settings.language.localized("Cloud backup needs attention")
    case .abandoned: model.settings.language.localized("Cloud backup skipped; kept on this iPhone")
    }
  }

  private func localStorageIcon(_ state: RecordingStatusPresentation.LocalFileState) -> String {
    switch state {
    case .notStarted, .saving, .saved: "iphone"
    case .unavailable: "iphone.slash"
    case .unknown: "questionmark.circle"
    }
  }

  private func localStorageColor(_ state: RecordingStatusPresentation.LocalFileState) -> Color {
    switch state {
    case .saved: .green
    case .saving: .cyan
    case .unavailable: .red
    case .unknown: .orange
    case .notStarted: .secondary
    }
  }

  private func recordingIcon(_ presentation: RecordingStatusPresentation) -> String {
    switch presentation.localFile {
    case .saved: "checkmark"
    case .unavailable: "exclamationmark"
    case .unknown: "questionmark"
    case .notStarted, .saving: "waveform"
    }
  }

  private func recordingColor(_ presentation: RecordingStatusPresentation) -> Color {
    switch presentation.localFile {
    case .saved: presentation.cloudBackup == .failed ? .orange : .green
    case .unavailable: .red
    case .unknown: .orange
    case .notStarted: .secondary
    case .saving: .cyan
    }
  }

  private func duration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    return String(
      format: "%02d:%02d:%02d",
      seconds / 3_600,
      seconds % 3_600 / 60,
      seconds % 60
    )
  }

  private func shortDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

private struct RecordingShareSheet: UIViewControllerRepresentable {
  let fileURL: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

func formattedStartDate(_ date: Date, language: AppLanguage) -> String {
  date.formatted(
    Date.FormatStyle(date: .abbreviated, time: .shortened)
      .locale(language.locale)
  )
}

func localizedSpeakerName(
  _ speaker: RealtimeSpeaker?,
  language: AppLanguage,
  personNames: [String: String] = [:]
) -> String {
  guard let speaker else { return language.localized("Unknown speaker") }
  if speaker.personID == RealtimeSpeaker.selfPersonID { return language.localized("Me") }
  if let personID = speaker.personID, let name = personNames[personID] { return name }
  let parts = speaker.displayName.split(separator: " ", omittingEmptySubsequences: true)
  if parts.count == 2, parts[0].localizedCaseInsensitiveCompare("Speaker") == .orderedSame,
    let number = Int(parts[1])
  {
    return String(format: language.localized("Speaker %d"), locale: language.locale, number)
  }
  if speaker.displayName.localizedCaseInsensitiveCompare("Unknown speaker") == .orderedSame {
    return language.localized("Unknown speaker")
  }
  return speaker.displayName
}

private struct RecordButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72),
        value: configuration.isPressed
      )
  }
}
