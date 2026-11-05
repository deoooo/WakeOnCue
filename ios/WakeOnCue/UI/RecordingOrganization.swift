import SwiftUI
import UIKit
import WakeOnCueCore

@MainActor
struct BookmarkButton: View {
  let recordingID: String
  let position: TimeInterval
  let service: RecordingAnnotationsService

  @State private var saved = false
  @State private var errorMessage: String?

  init(
    recordingID: String,
    position: TimeInterval,
    service: RecordingAnnotationsService = .shared
  ) {
    self.recordingID = recordingID
    self.position = position
    self.service = service
  }

  var body: some View {
    Button {
      do {
        try service.addBookmark(recordingID: recordingID, position: position)
        saved = true
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.5))
          saved = false
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    } label: {
      Label(
        saved ? "Bookmark saved" : "Add bookmark",
        systemImage: saved ? "checkmark" : "bookmark.fill")
    }
    .accessibilityIdentifier("add-recording-bookmark")
    .alert("Could not save bookmark", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }
}

@MainActor
struct RecordingOrganizationSection: View {
  @Environment(AppModel.self) private var model
  let recording: RecordingRecord
  let transcript: [RealtimeTranscriptEvent]
  let service: RecordingAnnotationsService
  let onSeek: (TimeInterval) -> Void
  let onShare: (RecordingShareItem) -> Void

  @State private var showsSpeakerEditor = false
  @State private var copied = false
  @State private var editingBookmark: RecordingBookmark?
  @State private var bookmarkTitle = ""
  @State private var errorMessage: String?

  init(
    recording: RecordingRecord,
    transcript: [RealtimeTranscriptEvent],
    service: RecordingAnnotationsService = .shared,
    onSeek: @escaping (TimeInterval) -> Void,
    onShare: @escaping (RecordingShareItem) -> Void = { _ in }
  ) {
    self.recording = recording
    self.transcript = transcript
    self.service = service
    self.onSeek = onSeek
    self.onShare = onShare
  }

  private var annotations: RecordingAnnotations {
    service.annotations(for: recording.id)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Bookmarks and transcript", systemImage: "bookmark.square.fill")
        .font(.headline)

      if annotations.bookmarks.isEmpty {
        Text("Bookmarks added while recording appear here.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 6) {
          ForEach(annotations.bookmarks) { bookmark in
            bookmarkRow(bookmark)
          }
        }
      }

      Divider()

      HStack(spacing: 10) {
        Button {
          copyTranscript()
        } label: {
          Label(
            copied ? "Copied" : "Copy transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(transcript.isEmpty)
        .accessibilityIdentifier("copy-recording-transcript")

        Menu {
          Button("Plain text") { export(.plainText) }
          Button("Subtitles (SRT)") { export(.srt) }
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(transcript.isEmpty)
        .accessibilityIdentifier("export-recording-transcript")

        Spacer(minLength: 0)
      }

      if !speakerClusters.isEmpty {
        Button {
          showsSpeakerEditor = true
        } label: {
          Label("Speaker names", systemImage: "person.2")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan)
        .frame(minHeight: 44)
        .accessibilityIdentifier("edit-recording-speaker-names")
      }

      if let storageError = service.errorsByRecordingID[recording.id] {
        Text(storageError)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .sheet(isPresented: $showsSpeakerEditor) {
      NavigationStack {
        SpeakerAliasEditor(
          recording: recording,
          transcript: transcript,
          speakers: speakerClusters,
          service: service
        )
      }
    }
    .alert("Rename bookmark", isPresented: renameBinding) {
      TextField("Optional title", text: $bookmarkTitle)
      Button("Cancel", role: .cancel) { editingBookmark = nil }
      Button("Save") { saveBookmarkTitle() }
    } message: {
      Text("Leave the title empty to show its timestamp.")
    }
    .alert("Could not update recording", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .accessibilityIdentifier("recording-organization")
  }

  private func bookmarkRow(_ bookmark: RecordingBookmark) -> some View {
    HStack(spacing: 10) {
      Button {
        onSeek(bookmark.position)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: bookmark.duration == nil ? "bookmark.fill" : "applewatch")
            .foregroundStyle(.cyan)
          VStack(alignment: .leading, spacing: 2) {
            Text(bookmark.displayTitle)
              .foregroundStyle(.primary)
            if bookmark.title != nil || bookmark.tag != nil || bookmark.duration != nil {
              Text(bookmark.timeRangeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(minHeight: 44)
      .accessibilityHint("Play from this bookmark")
      .accessibilityIdentifier("recording-bookmark-\(bookmark.id.uuidString)")

      Menu {
        Button("Rename") {
          bookmarkTitle = bookmark.title ?? ""
          editingBookmark = bookmark
        }
        Button("Delete", role: .destructive) { delete(bookmark) }
      } label: {
        Image(systemName: "ellipsis")
          .frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("Bookmark actions")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      Color(uiColor: .tertiarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }

  private var speakerClusters: [RealtimeSpeaker] {
    var known: [String: RealtimeSpeaker] = [:]
    for segment in transcript {
      guard let speaker = segment.speaker, speaker.clusterID != "speaker_unknown" else { continue }
      known[speaker.clusterID] = known[speaker.clusterID] ?? speaker
    }
    return known.values.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  private var renameBinding: Binding<Bool> {
    Binding(
      get: { editingBookmark != nil },
      set: { if !$0 { editingBookmark = nil } }
    )
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func delete(_ bookmark: RecordingBookmark) {
    do {
      try service.deleteBookmark(recordingID: recording.id, bookmarkID: bookmark.id)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveBookmarkTitle() {
    guard let bookmark = editingBookmark else { return }
    defer { editingBookmark = nil }
    do {
      try service.renameBookmark(
        recordingID: recording.id,
        bookmarkID: bookmark.id,
        title: bookmarkTitle
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func copyTranscript() {
    UIPasteboard.general.string = RecordingTranscriptExporter.plainText(
      transcript: transcript,
      speakerAliases: annotations.speakerAliases,
      personNames: model.settings.personNames
    )
    copied = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }

  private func export(_ format: RecordingTranscriptExportFormat) {
    do {
      onShare(
        try RecordingTranscriptExporter.write(
          recording: recording,
          transcript: transcript,
          speakerAliases: annotations.speakerAliases,
          personNames: model.settings.personNames,
          format: format,
          directory: RecordingFileLayout.transcriptExportDirectory(recordingID: recording.id)
        )
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
struct SpeakerAliasEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppModel.self) private var model

  let recording: RecordingRecord
  let transcript: [RealtimeTranscriptEvent]
  let speakers: [RealtimeSpeaker]
  let service: RecordingAnnotationsService

  @State private var drafts: [String: String]
  @State private var pickingContactFor: String?
  @State private var errorMessage: String?

  init(
    recording: RecordingRecord,
    transcript: [RealtimeTranscriptEvent],
    speakers: [RealtimeSpeaker],
    service: RecordingAnnotationsService = .shared
  ) {
    self.recording = recording
    self.transcript = transcript
    self.speakers = speakers
    self.service = service
    let aliases = service.annotations(for: recording.id).speakerAliases
    _drafts = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: speakers.map {
          ($0.clusterID, aliases[$0.clusterID] ?? "")
        })
    )
  }

  var body: some View {
    Form {
      Section {
        ForEach(speakers, id: \.clusterID) { speaker in
          row(for: speaker)
        }
      } footer: {
        Text(
          "Names apply to this recording and are used when copying or exporting. The original transcript stays unchanged."
        )
      }
    }
    .navigationTitle("Speaker names")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    .sheet(isPresented: contactPickerBinding) {
      ContactNamePicker { name in
        if let clusterID = pickingContactFor, let name {
          drafts[clusterID] = name
          save(clusterID)
        }
        pickingContactFor = nil
      }
      .ignoresSafeArea()
    }
    .alert("Could not save speaker name", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func row(for speaker: RealtimeSpeaker) -> some View {
    let clusterID = speaker.clusterID
    let recognized = speaker.personID.flatMap { model.settings.personNames[$0] }
    let savedName = normalized(service.annotations(for: recording.id).speakerAliases[clusterID])
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(localizedSpeakerName(speaker, language: model.settings.language))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let recognized {
          Label(recognized, systemImage: "person.wave.2.fill")
            .font(.caption)
            .foregroundStyle(.cyan)
        }
      }
      HStack {
        TextField("Name", text: draftBinding(for: clusterID))
          .textInputAutocapitalization(.words)
        Button {
          pickingContactFor = clusterID
        } label: {
          Image(systemName: "person.crop.circle.badge.plus")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Choose from Contacts"))
        Button("Save") { save(clusterID) }
          .buttonStyle(.borderless)
          .disabled(normalized(drafts[clusterID]) == savedName)
      }
    }
    .padding(.vertical, 3)
  }

  private var contactPickerBinding: Binding<Bool> {
    Binding(
      get: { pickingContactFor != nil },
      set: { if !$0 { pickingContactFor = nil } }
    )
  }

  private func draftBinding(for clusterID: String) -> Binding<String> {
    Binding(
      get: { drafts[clusterID] ?? "" },
      set: { drafts[clusterID] = $0 }
    )
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func normalized(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  private func save(_ clusterID: String) {
    do {
      try service.setSpeakerAlias(
        recordingID: recording.id,
        clusterID: clusterID,
        alias: drafts[clusterID]
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
