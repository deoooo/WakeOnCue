import SwiftUI
import WakeOnCueCore

struct RecordingDetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let recording: RecordingRecord
  /// Where playback starts when opened from a cited source, in seconds.
  let initialSeek: TimeInterval?

  @State private var displayedRecording: RecordingRecord
  @State private var isEditingTitle = false
  @State private var showsRecordingDetails = false
  @State private var transcript: [RealtimeTranscriptEvent] = []
  @State private var transcriptLoaded = false
  @State private var transcriptError: String?
  @State private var scrubberPosition: TimeInterval = 0
  @State private var isScrubbing = false
  @State private var activeSegmentID: String?
  @State private var transcriptFollowPolicy = TranscriptFollowPolicy()
  @State private var appliedInitialSeek = false
  @State private var notesDraft: MeetingNotesDraft?

  private let panel = Color(uiColor: .secondarySystemBackground)

  init(recording: RecordingRecord, initialSeek: TimeInterval? = nil) {
    self.recording = recording
    self.initialSeek = initialSeek
    _displayedRecording = State(initialValue: recording)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: true) {
        VStack(alignment: .leading, spacing: 18) {
          titleSection
          playbackSection
          retranscriptionProgress
          if let meetingLink {
            LinkedMeetingSection(link: meetingLink)
              .padding(16)
              .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          }
          summarySection
          transcriptSection(using: proxy)
          RecordingOrganizationSection(
            recording: displayedRecording,
            transcript: transcript,
            onSeek: { time in seek(to: time) },
            onShare: { item in model.shareItem = item }
          )
          recordingDetails
        }
        .padding(20)
        .padding(.bottom, 24)
      }
      .accessibilityIdentifier("transcript-scroll-view")
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !transcriptFollowPolicy.isFollowingPlayback,
          model.playingRecordingID == recording.id, !transcript.isEmpty
        {
          Button {
            let action = transcriptFollowPolicy.handle(.returnToPlayback)
            performTranscriptFollowAction(action, using: proxy)
          } label: {
            Label("Return to playback", systemImage: "scope")
              .font(.headline)
              .frame(maxWidth: .infinity, minHeight: 48)
          }
          .buttonStyle(.borderedProminent)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .background(.bar)
          .accessibilityLabel(model.settings.language.localized("Return to playback"))
          .accessibilityIdentifier("transcript-follow-playback")
        }
      }
      .onChange(of: transcriptLoaded) {
        guard transcriptLoaded, let initialSeek, !appliedInitialSeek else { return }
        appliedInitialSeek = true
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
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    .navigationTitle("Recording details")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task(id: "\(recording.id)-\(model.transcriptVersion)") {
      await refreshDisplayedRecording()
      await loadTranscript()
    }
    .sheet(item: $notesDraft) { draft in
      MeetingNotesComposer(draft: draft)
        .ignoresSafeArea()
    }
    .sheet(isPresented: $isEditingTitle) {
      RecordingTitleEditor(recording: displayedRecording) { updated in
        displayedRecording = updated
      }
      .environment(\.locale, model.settings.language.locale)
      .presentationDetents([.medium])
    }
    .onChange(of: model.playbackPosition) {
      guard model.playingRecordingID == recording.id else { return }
      if !isScrubbing { scrubberPosition = model.playbackPosition }
      activeSegmentID = segment(at: model.playbackPosition)?.id
    }
  }

  private var titleSection: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(displayedRecording.libraryDisplayTitle(language: model.settings.language))
        .font(.title2.weight(.bold))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        isEditingTitle = true
      } label: {
        Image(systemName: "pencil")
          .frame(minWidth: 44, minHeight: 44)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Edit recording title")
      .accessibilityIdentifier("edit-recording-title")

      Menu {
        Button {
          Task { await model.retranscribe(recording: displayedRecording) }
        } label: {
          Label(
            model.settings.useRealtimeProcessing ? "Retranscribe and identify speakers" : "Retranscribe",
            systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
          )
        }
        .disabled(model.retranscribingRecordingID != nil)
        .accessibilityIdentifier("retranscribe-recording")
      } label: {
        Image(systemName: "ellipsis.circle")
          .frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("More recording actions")
      .accessibilityIdentifier("more-recording-actions")
    }
  }

  private var playbackSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Button {
          Task { await model.togglePlayback(for: displayedRecording) }
        } label: {
          Image(systemName: isPlayingThisRecording ? "pause.fill" : "play.fill")
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(isPlayingThisRecording ? "Pause recording" : "Play recording")

        VStack(alignment: .leading, spacing: 2) {
          Text(isPlayingThisRecording ? "Playing" : "Playback")
            .font(.subheadline.weight(.semibold))
          Text(
            "\(playbackTimestamp(scrubberPosition)) / \(playbackTimestamp(playbackTotalDuration))"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          Task { await model.share(recording: displayedRecording) }
        } label: {
          Image(systemName: "square.and.arrow.up")
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Share")
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
                  for: displayedRecording,
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
                  for: displayedRecording,
                  to: max(0, scrubberPosition - 15),
                  autoplay: model.playbackIsPlaying
                )
              }
            } label: {
              Image(systemName: "gobackward.15")
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(model.settings.language.localized("Back 15 seconds"))

            Button {
              Task {
                await model.seekPlayback(
                  for: displayedRecording,
                  to: min(playbackTotalDuration, scrubberPosition + 15),
                  autoplay: model.playbackIsPlaying
                )
              }
            } label: {
              Image(systemName: "goforward.15")
                .frame(minWidth: 44, minHeight: 44)
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

    }
    .padding(16)
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  @ViewBuilder
  private var retranscriptionProgress: some View {
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
      .padding(.horizontal, 4)
      .accessibilityIdentifier("retranscription-progress")
    }
  }

  private func transcriptSection(using proxy: ScrollViewProxy) -> some View {
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
                  .foregroundStyle(.cyan)
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
    .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityIdentifier("recording-transcript")
  }

  private var meetingLink: MeetingLink? {
    MeetingLink(metadata: displayedRecording.metadata)
  }

  private func makeNotesDraft(summary: RecordingSummary) -> MeetingNotesDraft {
    let language = model.settings.language
    let title = displayedRecording.libraryDisplayTitle(language: language)
    return MeetingNotesDraft(
      subject: title,
      body: MeetingNotes.text(
        title: title,
        date: meetingLink?.start ?? displayedRecording.startedAt,
        summary: summary,
        language: language
      ),
      recipients: meetingLink.map(model.meetings.recipients) ?? []
    )
  }

  private var isProcessingOnDevice: Bool {
    model.onDeviceProcessingRecordingIDs.contains(recording.id)
  }

  @ViewBuilder
  private var summarySection: some View {
    let summary = model.summary(for: recording.id)
    if summary != nil || isProcessingOnDevice
      || (model.canSummarizeRecordings && !transcript.isEmpty)
    {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Summary", systemImage: "sparkles")
            .font(.headline)
          Spacer()
          if isProcessingOnDevice {
            ProgressView().controlSize(.small)
          } else if model.canSummarizeRecordings, !transcript.isEmpty {
            Button(summary == nil ? "Summarize" : "Regenerate") {
              Task {
                await model.processOnDevice(
                  recording: displayedRecording, regenerateSummary: true)
              }
            }
            .font(.subheadline)
            .accessibilityIdentifier("regenerate-recording-summary")
          }
        }
        if let summary {
          Text(summary.title).font(.subheadline.weight(.semibold))
          Text(summary.overview).font(.subheadline)
          if !summary.keyPoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Key points").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              ForEach(summary.keyPoints, id: \.self) { point in
                Label(point, systemImage: "circle.fill")
                  .labelStyle(SummaryBulletStyle())
              }
            }
          }
          if !summary.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Follow-ups").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              ForEach(summary.actionItems, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle")
                  .font(.subheadline)
              }
            }
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
          Button {
            notesDraft = makeNotesDraft(summary: summary)
          } label: {
            Label(
              meetingLink == nil ? "Share notes" : "Send notes to attendees",
              systemImage: "paperplane")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("send-meeting-notes")
        } else if isProcessingOnDevice {
          Text(
            model.settings.activeSpeechEndpoint == nil && model.settings.activeLanguageModelProvider == nil
              ? "Transcribing and summarizing on this iPhone…"
              : "Transcribing and summarizing with your service…"
          )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .accessibilityIdentifier("recording-summary")
    }
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

private struct SummaryBulletStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
      configuration.title.font(.subheadline)
    }
  }
}
