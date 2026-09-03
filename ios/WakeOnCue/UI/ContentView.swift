import AVFoundation
import SwiftUI
import UIKit
import WakeOnCueCore

struct ContentView: View {
  @Environment(AppModel.self) private var model

  private let accent = Color(red: 1.0, green: 0.25, blue: 0.34)
  private let canvas = Color(red: 0.035, green: 0.055, blue: 0.09)
  private let panel = Color.white.opacity(0.065)

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
            recorderPanel
            if model.realtimeState.isEnabled || !model.liveTranscriptSegments.isEmpty {
              liveTranscriptPanel
            }
            recentRecordings
          }
          .padding(.horizontal, 20)
          .padding(.top, 10)
          .padding(.bottom, 36)
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $model.settingsPresented) {
        SettingsView()
          .environment(model)
          .preferredColorScheme(.dark)
      }
      .sheet(item: $model.shareItem) { item in
        RecordingShareSheet(fileURL: item.url)
      }
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
    }
    .environment(\.locale, model.settings.language.locale)
    .preferredColorScheme(.dark)
  }

  private var liveTranscriptPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 9) {
        Image(systemName: "captions.bubble.fill")
          .foregroundStyle(.cyan)
        Text("Live transcript")
          .font(.headline)
        Spacer()
        realtimeStatusBadge
      }

      if model.liveTranscriptSegments.isEmpty {
        Text(emptyTranscriptMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 10)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
              ForEach(model.liveTranscriptSegments.suffix(6)) { segment in
                transcriptRow(segment)
                  .id(segment.id)
              }
            }
          }
          .frame(maxHeight: 250)
          .onAppear { scrollToLatestTranscript(using: proxy, animated: false) }
          .onChange(of: model.realtimeUpdateSequence) {
            scrollToLatestTranscript(using: proxy, animated: true)
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.07)))
  }

  private func scrollToLatestTranscript(using proxy: ScrollViewProxy, animated: Bool) {
    guard let id = model.liveTranscriptSegments.last?.id else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .bottom) }
    } else {
      proxy.scrollTo(id, anchor: .bottom)
    }
  }

  private var realtimeStatusBadge: some View {
    let (title, color): (String, Color) =
      switch model.realtimeState {
      case .disabled: (model.settings.language.localized("Finished"), .secondary)
      case .connecting: (model.settings.language.localized("Connecting"), .orange)
      case .waitingForProcessor:
        (model.settings.language.localized("Waiting for processor"), .orange)
      case .processing: (model.settings.language.localized("Live"), .green)
      case .reconnecting: (model.settings.language.localized("Reconnecting"), .orange)
      case .unavailable: (model.settings.language.localized("Offline"), .secondary)
      }
    return Text(title)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .foregroundStyle(color)
      .background(color.opacity(0.13), in: Capsule())
      .accessibilityIdentifier("realtime-status")
  }

  private var emptyTranscriptMessage: String {
    switch model.realtimeState {
    case .waitingForProcessor:
      model.settings.language.localized("Recording is safe. Waiting for an analysis processor.")
    case .unavailable(let message): message
    default: model.settings.language.localized("Listening for speech…")
    }
  }

  private func transcriptRow(_ segment: RealtimeTranscriptEvent) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(timestamp(milliseconds: segment.startMilliseconds))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(width: 38, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(localizedSpeakerName(segment.speaker, language: model.settings.language))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.cyan)
        Text(segment.text)
          .font(.subheadline)
          .foregroundStyle(segment.isFinal ? .primary : .secondary)
          .italic(!segment.isFinal)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("live-transcript-segment-\(segment.id)")
  }

  private func timestamp(milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds / 1_000)
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
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
      LinearGradient(
        colors: [Color.white.opacity(0.035), .clear],
        startPoint: .top,
        endPoint: .center
      )
      .ignoresSafeArea()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(accent.opacity(0.16))
        Image(systemName: "waveform")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(accent)
      }
      .frame(width: 42, height: 42)

      VStack(alignment: .leading, spacing: 2) {
        Text("WakeOnCue")
          .font(.title3.weight(.bold))
        Text("Never miss a meeting")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        model.settingsPresented = true
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 42, height: 42)
          .background(panel, in: Circle())
          .overlay(Circle().stroke(.white.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Recording storage settings")
    }
  }

  private var permissionBanner: some View {
    HStack(spacing: 13) {
      Image(systemName: "mic.badge.plus")
        .font(.system(size: 19, weight: .semibold))
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
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08)))
  }

  private var recorderPanel: some View {
    VStack(spacing: 0) {
      statusPill
        .padding(.top, 25)

      Text(duration(model.elapsed))
        .font(.system(size: 54, weight: .medium, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText())
        .padding(.top, 16)

      if let recordingSubtitle {
        Text(recordingSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      }

      controls
        .padding(.vertical, 28)

      if !model.settings.useS3 {
        Divider()
          .overlay(.white.opacity(0.08))
          .padding(.horizontal, 20)
        localStorageIndicator
          .padding(16)
      }
    }
    .frame(maxWidth: .infinity)
    .background(
      LinearGradient(
        colors: [Color.white.opacity(0.095), Color.white.opacity(0.045)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 30, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .stroke(.white.opacity(0.1))
    )
    .shadow(color: .black.opacity(0.25), radius: 26, y: 16)
    .accessibilityElement(children: .contain)
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
    case .recording:
      activeControls(
        primaryTitle: model.settings.language.localized("Pause"),
        primaryIcon: "pause.fill",
        primaryColor: .orange
      ) {
        await model.pauseRecording()
      }
    case .paused:
      activeControls(
        primaryTitle: model.settings.language.localized("Resume"),
        primaryIcon: "play.fill",
        primaryColor: .green
      ) {
        await model.resumeRecording()
      }
    case .finishing, .uploading:
      VStack(spacing: 12) {
        ProgressView()
          .controlSize(.large)
          .tint(.cyan)
        Text(
          model.settings.useS3
            ? model.settings.language.localized("Securing local audio and syncing")
            : model.settings.language.localized("Finishing your local recording")
        )
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
        .accessibilityHint("Stops waiting for cloud sync and keeps this recording on this iPhone")
      }
      .frame(minHeight: 142)
    default:
      Button {
        Task { await model.startRecording() }
      } label: {
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
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.isBusy || model.microphonePermission == .denied)
      .accessibilityLabel("Start meeting recording")
      .accessibilityIdentifier("start-recording")
    }
  }

  private func activeControls(
    primaryTitle: String,
    primaryIcon: String,
    primaryColor: Color,
    primaryAction: @escaping () async -> Void
  ) -> some View {
    HStack(spacing: 34) {
      roundAction(primaryTitle, icon: primaryIcon, color: primaryColor, action: primaryAction)
      roundAction(model.settings.language.localized("Finish"), icon: "stop.fill", color: accent) {
        await model.finishRecording()
      }
      .accessibilityIdentifier("finish-recording")
    }
  }

  private func roundAction(
    _ title: String,
    icon: String,
    color: Color,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      VStack(spacing: 9) {
        Image(systemName: icon)
          .font(.system(size: 23, weight: .bold))
          .frame(width: 62, height: 62)
          .background(color.opacity(0.16), in: Circle())
          .overlay(Circle().stroke(color.opacity(0.25)))
          .foregroundStyle(color)
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
      }
    }
    .buttonStyle(.plain)
    .disabled(model.isBusy)
  }

  private var recentRecordings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent recordings")
          .font(.headline)
        Spacer()
        Text("Stored locally")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    let audioAvailable = [.uploading, .completed, .failed].contains(recording.status)
    return HStack(spacing: 13) {
      NavigationLink {
        RecordingDetailView(recording: recording)
          .environment(model)
      } label: {
        HStack(spacing: 13) {
          Image(systemName: recording.status == .completed ? "checkmark" : "waveform")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(recording.status == .completed ? .green : .orange)
            .frame(width: 38, height: 38)
            .background(
              (recording.status == .completed ? Color.green : Color.orange).opacity(0.12),
              in: Circle()
            )
          VStack(alignment: .leading, spacing: 3) {
            Text(formattedStartDate(recording.startedAt, language: model.settings.language))
              .font(.subheadline.weight(.semibold))
            Text("\(duration(recording.duration)) · \(recordingStateLabel(recording.status))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 6)
          if model.settings.useS3 && progress.pendingDuration > 0.5 {
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
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.055)))
  }

  private var localStorageIndicator: some View {
    HStack(spacing: 12) {
      Image(systemName: "iphone")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.green)
        .frame(width: 38, height: 38)
        .background(.green.opacity(0.12), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text("Saved locally")
          .font(.subheadline.weight(.semibold))
        Text("No cloud storage configured")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
    .padding(12)
    .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var recordingSubtitle: String? {
    switch model.currentRecording?.status {
    case .recording: nil
    case .paused: model.settings.language.localized("Capture paused · session preserved")
    case .finishing, .uploading:
      model.settings.useS3
        ? model.settings.language.localized("Finalizing and syncing your meeting")
        : model.settings.language.localized("Finishing local recording")
    case .completed:
      model.settings.useS3
        ? model.settings.language.localized("Everything is safely synced")
        : model.settings.language.localized("Saved safely on this iPhone")
    case .failed:
      model.settings.useS3
        ? model.settings.language.localized("Local audio is safe · sync needs attention")
        : model.settings.language.localized("Local audio is safe")
    default: model.settings.language.localized("Tap once when your meeting begins")
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
    switch status {
    case .ready: model.settings.language.localized("Ready")
    case .recording: model.settings.language.localized("Recording")
    case .paused: model.settings.language.localized("Paused")
    case .finishing: model.settings.language.localized("Finishing")
    case .uploading:
      model.settings.useS3
        ? model.settings.language.localized("Syncing")
        : model.settings.language.localized("Finishing")
    case .completed: model.settings.language.localized("Completed")
    case .failed: model.settings.language.localized("Needs attention")
    }
  }

  private func recordingStateLabel(_ status: RecordingStatus) -> String {
    switch status {
    case .ready: model.settings.language.localized("Ready")
    case .recording: model.settings.language.localized("Recording")
    case .paused: model.settings.language.localized("Paused")
    case .finishing: model.settings.language.localized("Finishing")
    case .uploading:
      model.settings.useS3
        ? model.settings.language.localized("Syncing")
        : model.settings.language.localized("Finalizing")
    case .completed:
      model.settings.useS3
        ? model.settings.language.localized("Synced")
        : model.settings.language.localized("Saved locally")
    case .failed:
      model.settings.useS3
        ? model.settings.language.localized("Sync needs attention")
        : model.settings.language.localized("Saved locally")
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

private struct RecordingDetailView: View {
  @Environment(AppModel.self) private var model
  let recording: RecordingRecord

  @State private var transcript: [RealtimeTranscriptEvent] = []
  @State private var transcriptLoaded = false
  @State private var transcriptError: String?
  @State private var scrubberPosition: TimeInterval = 0
  @State private var isScrubbing = false
  @State private var activeSegmentID: String?

  private let panel = Color.white.opacity(0.065)

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) {
        summary
        transcriptSection
      }
      .padding(20)
      .padding(.bottom, 24)
    }
    .background(Color(red: 0.035, green: 0.055, blue: 0.09).ignoresSafeArea())
    .navigationTitle("Recording details")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task(id: "\(recording.id)-\(model.transcriptVersion)") { await loadTranscript() }
    .onChange(of: model.playbackPosition) {
      guard model.playingRecordingID == recording.id else { return }
      if !isScrubbing { scrubberPosition = model.playbackPosition }
      activeSegmentID = segment(at: model.playbackPosition)?.id
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Recording file", systemImage: "waveform")
          .font(.headline)
        Spacer()
        Text(statusLabel)
          .font(.caption.weight(.bold))
          .foregroundStyle(recording.status == .completed ? .green : .orange)
      }

      Divider().overlay(.white.opacity(0.08))
      detailRow(
        "Started",
        formattedStartDate(recording.startedAt, language: model.settings.language)
      )
      detailRow("Duration", formattedDuration(recording.duration))
      detailRow("Device", recording.deviceModel)

      HStack(spacing: 12) {
        Button {
          Task { await model.togglePlayback(for: recording) }
        } label: {
          Label(
            isPlayingThisRecording ? "Pause recording" : "Play recording",
            systemImage: isPlayingThisRecording ? "pause.fill" : "play.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)

        Button {
          Task { await model.share(recording: recording) }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }

      VStack(spacing: 8) {
        Slider(
          value: $scrubberPosition,
          in: 0...max(playbackTotalDuration, 0.01),
          onEditingChanged: { editing in
            isScrubbing = editing
            if !editing {
              Task {
                await model.seekPlayback(
                  for: recording,
                  to: scrubberPosition,
                  autoplay: model.playbackIsPlaying
                )
              }
            }
          }
        )
        .tint(.cyan)
        .accessibilityIdentifier("recording-playback-slider")

        HStack {
          Text(playbackTimestamp(scrubberPosition))
          Spacer()
          HStack(spacing: 22) {
            Button {
              Task {
                await model.seekPlayback(
                  for: recording,
                  to: max(0, scrubberPosition - 15),
                  autoplay: model.playbackIsPlaying
                )
              }
            } label: {
              Image(systemName: "gobackward.15")
            }
            .accessibilityLabel(model.settings.language.localized("Back 15 seconds"))

            Button {
              Task {
                await model.seekPlayback(
                  for: recording,
                  to: min(playbackTotalDuration, scrubberPosition + 15),
                  autoplay: model.playbackIsPlaying
                )
              }
            } label: {
              Image(systemName: "goforward.15")
            }
            .accessibilityLabel(model.settings.language.localized("Forward 15 seconds"))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.cyan)
          Spacer()
          Text(playbackTimestamp(playbackTotalDuration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }

      Button {
        Task { await model.retranscribe(recording: recording) }
      } label: {
        Label(
          "Retranscribe and identify speakers",
          systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(model.retranscribingRecordingID != nil)
      .accessibilityIdentifier("retranscribe-recording")

      if model.retranscribingRecordingID == recording.id {
        VStack(alignment: .leading, spacing: 7) {
          ProgressView(value: model.retranscriptionProgress)
          Text(
            model.retranscriptionStatusMessage
              ?? model.settings.language.localized("Transcribing and identifying speakers…")
          )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("retranscription-progress")
      }
    }
    .padding(16)
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Transcript", systemImage: "captions.bubble.fill")
        .font(.headline)
        .foregroundStyle(.primary)

      if !transcriptLoaded {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 18)
      } else if let transcriptError {
        Text(transcriptError)
          .font(.subheadline)
          .foregroundStyle(.orange)
      } else if transcript.isEmpty {
        Text("No transcript was produced for this recording.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(transcript) { segment in
                HStack(alignment: .top, spacing: 10) {
                  Text(timestamp(segment.startMilliseconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                      activeSegmentID == segment.id ? Color.white : Color.secondary
                    )
                    .frame(width: 42, alignment: .leading)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(localizedSpeakerName(segment.speaker, language: model.settings.language))
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.cyan)
                    Text(segment.text)
                      .font(.body)
                      .textSelection(.enabled)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                  activeSegmentID == segment.id ? Color.cyan.opacity(0.16) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { seek(to: segment) }
                .id(segment.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(
                  model.settings.language.localized("Play from this transcript position")
                )
                .accessibilityIdentifier("recording-transcript-segment-\(segment.id)")
              }
            }
          }
          .frame(minHeight: 220, maxHeight: 430)
          .onChange(of: activeSegmentID) {
            guard model.playingRecordingID == recording.id,
              model.playbackIsPlaying,
              let activeSegmentID
            else { return }
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(activeSegmentID, anchor: .center)
            }
          }
          .simultaneousGesture(
            DragGesture(minimumDistance: 44).onEnded { value in
              guard abs(value.translation.height) > abs(value.translation.width) else { return }
              switchTranscript(by: value.translation.height < 0 ? 1 : -1)
            }
          )
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityIdentifier("recording-transcript")
  }

  private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
    }
    .font(.subheadline)
  }

  private var statusLabel: String {
    switch recording.status {
    case .ready: model.settings.language.localized("Ready")
    case .recording: model.settings.language.localized("Recording")
    case .paused: model.settings.language.localized("Paused")
    case .finishing: model.settings.language.localized("Finishing")
    case .uploading: model.settings.language.localized("Finalizing")
    case .completed: model.settings.language.localized("Completed")
    case .failed: model.settings.language.localized("Needs attention")
    }
  }

  private func loadTranscript() async {
    defer { transcriptLoaded = true }
    do {
      transcript = try await model.transcript(for: recording.id)
      if model.playingRecordingID == recording.id {
        scrubberPosition = model.playbackPosition
        activeSegmentID = segment(at: model.playbackPosition)?.id
      }
      transcriptError = nil
    } catch {
      transcriptError = String(
        format: model.settings.language.localized("Could not load transcript: %@"),
        error.localizedDescription
      )
    }
  }

  private func formattedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    return String(
      format: "%02d:%02d:%02d",
      seconds / 3_600,
      seconds % 3_600 / 60,
      seconds % 60
    )
  }

  private func timestamp(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1_000)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private var isPlayingThisRecording: Bool {
    model.playingRecordingID == recording.id && model.playbackIsPlaying
  }

  private var playbackTotalDuration: TimeInterval {
    if model.playingRecordingID == recording.id, model.playbackDuration > 0 {
      return model.playbackDuration
    }
    return max(0, recording.duration)
  }

  private func playbackTimestamp(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private func segment(at time: TimeInterval) -> RealtimeTranscriptEvent? {
    let milliseconds = Int(max(0, time) * 1_000)
    if let containing = transcript.first(where: {
      $0.startMilliseconds <= milliseconds
        && $0.endMilliseconds > milliseconds
    }) {
      return containing
    }
    return transcript.last { $0.startMilliseconds <= milliseconds }
  }

  private func seek(to segment: RealtimeTranscriptEvent) {
    activeSegmentID = segment.id
    scrubberPosition = TimeInterval(segment.startMilliseconds) / 1_000
    Task { await model.seekPlayback(for: recording, to: scrubberPosition) }
  }

  private func switchTranscript(by offset: Int) {
    guard !transcript.isEmpty else { return }
    let currentIndex = activeSegmentID.flatMap { id in
      transcript.firstIndex(where: { $0.id == id })
    } ?? 0
    let destination = min(max(0, currentIndex + offset), transcript.count - 1)
    seek(to: transcript[destination])
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

func localizedSpeakerName(_ speaker: RealtimeSpeaker?, language: AppLanguage) -> String {
  guard let speaker else { return language.localized("Unknown speaker") }
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
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
  }
}
