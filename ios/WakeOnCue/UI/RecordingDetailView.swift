import SwiftUI
import WakeOnCueCore

struct RecordingDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss
  let recording: RecordingRecord
  /// Where playback starts when opened from a cited source, in seconds.
  let initialSeek: TimeInterval?

  @State private var displayedRecording: RecordingRecord
  @State private var isEditingTitle = false
  @State private var isRetranscribeConfirmationPresented = false
  @State private var showsRecordingDetails = false
  @State private var transcript: [RealtimeTranscriptEvent] = []
  @State private var transcriptLoaded = false
  @State private var transcriptError: String?
  @State private var scrubberPosition: TimeInterval = 0
  @State private var isScrubbing = false
  @State private var activeSegmentID: String?
  @State private var transcriptFollowPolicy = TranscriptFollowPolicy()
  @State private var appliedInitialSeek = false
  @State private var page = DetailPage.summary
  @State private var isSpokenLanguageSupported = true

  private let panel = Color(uiColor: .secondarySystemBackground)

  init(recording: RecordingRecord, initialSeek: TimeInterval? = nil) {
    self.recording = recording
    self.initialSeek = initialSeek
    _displayedRecording = State(initialValue: recording)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: true) {
        VStack(alignment: .leading, spacing: 16) {
          header
          Picker("View", selection: $page) {
            Text("Summary").tag(DetailPage.summary)
            Text("Transcript").tag(DetailPage.transcript)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("detail-page-picker")
          retranscriptionProgress
          switch page {
          case .summary:
            summarySection
          case .transcript:
            transcriptSection(using: proxy)
            RecordingOrganizationSection(
              recording: displayedRecording,
              transcript: transcript,
              onSeek: { time in page = .transcript; seek(to: time) },
              onShare: { item in model.shareItem = item }
            )
            recordingDetails
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .accessibilityIdentifier("transcript-scroll-view")
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          if page == .transcript, !transcriptFollowPolicy.isFollowingPlayback,
            model.playingRecordingID == recording.id, !transcript.isEmpty
          {
            Button {
              let action = transcriptFollowPolicy.handle(.returnToPlayback)
              performTranscriptFollowAction(action, using: proxy)
            } label: {
              Label("Return to playback", systemImage: "scope")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("transcript-follow-playback")
          }
          playbackSection
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }
      .onChange(of: transcriptLoaded) {
        guard transcriptLoaded, let initialSeek, !appliedInitialSeek else { return }
        appliedInitialSeek = true
        page = .transcript
        seek(to: initialSeek)
        if let activeSegmentID { proxy.scrollTo(activeSegmentID, anchor: .center) }
      }
      .onScrollPhaseChange { _, newPhase in
        guard newPhase == .tracking || newPhase == .interacting else { return }
        _ = transcriptFollowPolicy.handle(.manualScrollBegan)
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 8).onChanged { value in
          guard abs(value.translation.height) > abs(value.translation.width) else { return }
          _ = transcriptFollowPolicy.handle(.manualScrollBegan)
        }
      )
    }
    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar { toolbarItems }
    .task(id: "\(recording.id)-\(model.transcriptVersion)") {
      await refreshDisplayedRecording()
      await loadTranscript()
    }
    .task(id: "\(model.settings.spokenLanguage)-\(model.settings.activeSpeechEndpoint == nil)") {
      isSpokenLanguageSupported = await model.transcriptionSupportsSpokenLanguage()
    }
    .sheet(isPresented: $isEditingTitle) {
      RecordingTitleEditor(recording: displayedRecording) { updated in
        displayedRecording = updated
      }
      .environment(\.locale, model.settings.language.locale)
      .presentationDetents([.medium])
    }
    .confirmationDialog(
      "Replace this transcript?",
      isPresented: $isRetranscribeConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Replace transcript", role: .destructive) {
        Task { await model.retranscribe(recording: displayedRecording) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if transcriptError != nil {
        Text("The existing transcript could not be read, so it may still hold content. Try again first if you can.")
      } else {
        Text("The speaker labels and names in this transcript will be removed and cannot be recovered.")
      }
    }
    .onChange(of: model.playbackPosition) {
      guard model.playingRecordingID == recording.id else { return }
      if !isScrubbing { scrubberPosition = model.playbackPosition }
      activeSegmentID = segment(at: model.playbackPosition)?.id
    }
  }

  private var header: some View {
    let language = model.settings.language
    return VStack(alignment: .leading, spacing: 6) {
      Text(conversationTitle(displayedRecording, language: language))
        .font(.title2.weight(.bold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 6) {
        Text(displayedRecording.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(language.locale)))
        Text(recordingTimeRange(displayedRecording, language: language)).monospacedDigit()
        Text("·")
        Text(spokenDuration(displayedRecording.duration, language: language))
        Text("·")
        Label(RecordingSource(displayedRecording).title, systemImage: RecordingSource(displayedRecording).symbol)
          .imageScale(.small)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
    }
  }

  @ToolbarContentBuilder
  private var toolbarItems: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Menu {
        Button {
          Task { await model.share(recording: displayedRecording) }
        } label: {
          Label("Share audio", systemImage: "waveform")
        }
        if let summary = model.summary(for: recording.id) {
          ShareLink(item: summaryText(summary)) {
            Label("Share summary", systemImage: "text.alignleft")
          }
        }
      } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      .accessibilityIdentifier("share-recording")

      Menu {
        Button {
          isEditingTitle = true
        } label: {
          Label("Rename", systemImage: "pencil")
        }
        .accessibilityIdentifier("edit-recording-title")

        Button {
          Task { await model.processOnDevice(recording: displayedRecording, regenerateSummary: true) }
        } label: {
          Label("Regenerate summary", systemImage: "sparkles")
        }
        .disabled(!model.canSummarizeRecordings || transcript.isEmpty || isProcessingOnDevice)
        .accessibilityIdentifier("regenerate-recording-summary")

        Button {
          if transcriptError != nil || transcript.contains(where: { $0.speaker != nil }) {
            isRetranscribeConfirmationPresented = true
          } else {
            Task { await model.retranscribe(recording: displayedRecording) }
          }
        } label: {
          Label("Retranscribe", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .disabled(
          !transcriptLoaded || model.retranscribingRecordingID != nil
            || !model.canTranscribeRecordings)
        .accessibilityIdentifier("retranscribe-recording")

        Divider()

        Button(role: .destructive) {
          Task {
            if await model.moveToTrash(displayedRecording) { dismiss() }
          }
        } label: {
          Label("Delete recording", systemImage: "trash")
        }
        .disabled(!displayedRecording.canBeDeleted)
        .accessibilityIdentifier("delete-recording")
      } label: {
        Label("More recording actions", systemImage: "ellipsis")
      }
      .accessibilityIdentifier("more-recording-actions")
    }
  }

  private func summaryText(_ summary: RecordingSummary) -> String {
    let language = model.settings.language
    var lines = [displayedRecording.libraryDisplayTitle(language: language),
                 formattedStartDate(displayedRecording.startedAt, language: language), "",
                 summary.overview]
    if !summary.keyPoints.isEmpty {
      lines += ["", language.localized("Key points")] + summary.keyPoints.map { "• \($0)" }
    }
    if !summary.actionItems.isEmpty {
      lines += ["", language.localized("To-dos")] + summary.actionItems.map { "☐ \($0)" }
    }
    return lines.joined(separator: "\n")
  }

  private var playbackSection: some View {
    VStack(spacing: 4) {
      Slider(
        value: $scrubberPosition,
        in: 0...max(playbackTotalDuration, 0.01),
        onEditingChanged: { editing in
          isScrubbing = editing
          if !editing {
            Task {
              await model.seekPlayback(
                for: displayedRecording,
                to: scrubberPosition,
                autoplay: model.playbackIsPlaying
              )
            }
          }
        }
      )
      .accessibilityIdentifier("recording-playback-slider")

      HStack {
        Text(playbackTimestamp(scrubberPosition))
          .frame(width: 64, alignment: .leading)
        Spacer()
        Button {
          Task {
            await model.seekPlayback(
              for: displayedRecording, to: max(0, scrubberPosition - 15),
              autoplay: model.playbackIsPlaying)
          }
        } label: {
          Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel(model.settings.language.localized("Back 15 seconds"))

        Button {
          Task { await model.togglePlayback(for: displayedRecording) }
        } label: {
          Group {
            if model.isAudioBusy(recording.id) && !isPlayingThisRecording {
              ProgressView().tint(Color(uiColor: .systemBackground))
            } else {
              Image(systemName: isPlayingThisRecording ? "pause.fill" : "play.fill").font(.title3)
            }
          }
          .foregroundStyle(Color(uiColor: .systemBackground))
          .frame(width: 52, height: 52)
          .background(Color.primary, in: Circle())
        }
        .accessibilityLabel(isPlayingThisRecording ? "Pause recording" : "Play recording")
        .accessibilityIdentifier("recording-play")

        Button {
          Task {
            await model.seekPlayback(
              for: displayedRecording, to: min(playbackTotalDuration, scrubberPosition + 15),
              autoplay: model.playbackIsPlaying)
          }
        } label: {
          Image(systemName: "goforward.15").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel(model.settings.language.localized("Forward 15 seconds"))
        Spacer()
        Text("-" + playbackTimestamp(max(0, playbackTotalDuration - scrubberPosition)))
          .frame(width: 64, alignment: .trailing)
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .buttonStyle(.plain)
    }
    .tint(.primary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
  }

  @ViewBuilder
  private var retranscriptionProgress: some View {
    if model.retranscribingRecordingID == recording.id {
      VStack(alignment: .leading, spacing: 7) {
        ProgressView(value: model.retranscriptionProgress)
        Text(
          model.retranscriptionStatusMessage
            ?? model.settings.language.localized("Transcribing…")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
      .accessibilityIdentifier("retranscription-progress")
    }
  }

  @ViewBuilder
  private var transcribeButton: some View {
    if model.canTranscribeRecordings {
      Button {
        Task { await model.processOnDevice(recording: displayedRecording) }
      } label: {
        if model.settings.activeSpeechEndpoint == nil {
          Label("Transcribe on this iPhone", systemImage: "iphone.gen3")
        } else {
          Label("Transcribe with your service", systemImage: "cloud")
        }
      }
      .buttonStyle(.bordered)
      .disabled(isProcessingOnDevice)
      .accessibilityIdentifier("transcribe-on-device")
    }
  }

  private func transcriptSection(using proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if !transcriptLoaded {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 18)
      } else if let transcriptError {
        Text(transcriptError)
          .font(.subheadline)
          .foregroundStyle(.orange)
        Button {
          Task {
            transcriptLoaded = false
            await loadTranscript()
          }
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
      } else if transcript.isEmpty {
        if isProcessingOnDevice || model.retranscribingRecordingID == recording.id {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.settings.language.localized("Transcribing…"))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        } else if model.canTranscribeRecordings, isSpokenLanguageSupported {
          Text("No transcript was produced for this recording.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
          transcribeButton
        } else {
          serviceSetupHint(
            model.canTranscribeRecordings
              ? OnDeviceIntelligence.spokenLanguageUnsupportedMessage
              : OnDeviceIntelligence.transcriptionUnavailableMessage,
            action: "Set up transcription",
            identifier: "set-up-transcription"
          )
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(transcript) { segment in
              HStack(alignment: .top, spacing: 10) {
                Text(timestamp(segment.startMilliseconds))
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(
                    activeSegmentID == segment.id ? Color.primary : Color.secondary
                  )
                  .frame(minWidth: 42, alignment: .leading)
                  .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                  if segment.speaker != nil {
                    Text(
                      effectiveSpeakerName(
                        segment.speaker,
                        aliases: RecordingAnnotationsService.shared
                          .annotations(for: recording.id).speakerAliases,
                        personNames: model.settings.personNames,
                        unknownSpeakerName: localizedSpeakerName(
                          nil,
                          language: model.settings.language
                        )
                      )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  }
                  Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 9)
              .frame(minHeight: 44)
              .background(
                activeSegmentID == segment.id ? Color.accentColor.opacity(0.14) : Color.clear,
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
          .onChange(of: activeSegmentID) {
            guard model.playingRecordingID == recording.id,
              model.playbackIsPlaying
            else { return }
            let action = transcriptFollowPolicy.handle(.playbackPositionChanged)
            performTranscriptFollowAction(action, using: proxy)
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recording-transcript")
  }

  private func serviceSetupHint(
    _ message: String, action: LocalizedStringKey, identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action) { model.settingsPresented = true }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }
  }

  private var isProcessingOnDevice: Bool {
    model.onDeviceProcessingRecordingIDs.contains(recording.id)
  }

  @ViewBuilder
  private var summarySection: some View {
    let summary = model.summary(for: recording.id)
    VStack(alignment: .leading, spacing: 12) {
      if let summary {
        VStack(alignment: .leading, spacing: 12) {
          Text(summary.overview)
            .font(.body.weight(.semibold))
            .textSelection(.enabled)
          if !summary.keyPoints.isEmpty {
            Text("Key points").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(summary.keyPoints, id: \.self) { point in
              Label(point, systemImage: "circle.fill")
                .labelStyle(SummaryBulletStyle())
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        if !summary.actionItems.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("To-dos").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(summary.actionItems, id: \.self) { item in
              TodoRow(recordingID: recording.id, item: item)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }

        Group {
          if let generatedBy = summary.generatedBy {
            Text("Written by \(generatedBy). Check it against the transcript.")
          } else {
            Text("Written on this iPhone by Apple Intelligence. Check it against the transcript.")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
      } else if isProcessingOnDevice {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(
            model.settings.activeSpeechEndpoint == nil && model.settings.activeLanguageModelProvider == nil
              ? "Transcribing and summarizing on this iPhone…"
              : "Transcribing and summarizing with your service…"
          )
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(16)
      } else if !model.canSummarizeRecordings {
        serviceSetupHint(
          OnDeviceIntelligence.summaryUnavailableMessage,
          action: "Set up summaries",
          identifier: "set-up-summaries"
        )
        .padding(16)
      } else if transcriptLoaded, transcript.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("There is no transcript to summarize yet.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          transcribeButton
        }
        .padding(16)
      } else if !transcript.isEmpty {
        Button {
          Task { await model.processOnDevice(recording: displayedRecording, regenerateSummary: true) }
        } label: {
          Label("Summarize", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .padding(16)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recording-summary")
  }

  private var recordingDetails: some View {
    DisclosureGroup(isExpanded: $showsRecordingDetails) {
      VStack(spacing: 10) {
        detailRow(
          "Started",
          formattedStartDate(displayedRecording.startedAt, language: model.settings.language)
        )
        detailRow("Duration", formattedDuration(displayedRecording.duration))
        detailRow("Device", displayedRecording.deviceModel)
        detailRow("File", URL(filePath: displayedRecording.localAudioPath).lastPathComponent)
        detailRow("Status", displayedRecording.storageStatusText(language: model.settings.language))
      }
      .padding(.top, 12)
    } label: {
      Label("Recording details", systemImage: "info.circle")
        .font(.headline)
    }
    .padding(16)
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityIdentifier("recording-file-details")
  }

  private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
    }
    .font(.subheadline)
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

  @MainActor
  private func refreshDisplayedRecording() async {
    if let recent = model.recentRecordings.first(where: { $0.id == recording.id }) {
      displayedRecording = recent
      return
    }

    do {
      let service = try RecordingLibraryService(layout: RecordingFileLayout())
      displayedRecording = try await service.recording(id: recording.id)
    } catch {
      // The navigation snapshot remains a valid fallback when the store cannot be refreshed.
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
    return max(0, displayedRecording.duration)
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
    seek(to: TimeInterval(segment.startMilliseconds) / 1_000)
  }

  private func seek(to time: TimeInterval) {
    scrubberPosition = max(0, time)
    activeSegmentID = segment(at: scrubberPosition)?.id
    Task { await model.seekPlayback(for: displayedRecording, to: scrubberPosition) }
  }

  private func performTranscriptFollowAction(
    _ action: TranscriptFollowPolicy.Action,
    using proxy: ScrollViewProxy
  ) {
    guard action == .scrollToPlayback else { return }
    let destinationID = activeSegmentID ?? segment(at: model.playbackPosition)?.id
    guard let destinationID else { return }

    if reduceMotion {
      proxy.scrollTo(destinationID, anchor: .center)
    } else {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(destinationID, anchor: .center)
      }
    }
  }
}

struct TranscriptFollowPolicy: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    case playbackPositionChanged
    case manualScrollBegan
    case returnToPlayback
  }

  enum Action: Equatable, Sendable {
    case none
    case scrollToPlayback
  }

  private(set) var isFollowingPlayback = true

  mutating func handle(_ event: Event) -> Action {
    switch event {
    case .manualScrollBegan:
      isFollowingPlayback = false
      return .none
    case .playbackPositionChanged:
      return isFollowingPlayback ? .scrollToPlayback : .none
    case .returnToPlayback:
      isFollowingPlayback = true
      return .scrollToPlayback
    }
  }
}

enum DetailPage: Hashable {
  case summary
  case transcript
}

private struct SummaryBulletStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
      configuration.title.font(.subheadline)
    }
  }
}
