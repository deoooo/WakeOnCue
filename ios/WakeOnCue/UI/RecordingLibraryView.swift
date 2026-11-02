import SwiftUI
import UniformTypeIdentifiers
import WakeOnCueCore

struct RecordingLibraryView: View {
  @Environment(AppModel.self) private var model
  @State private var isImporting = false
  @State private var showsRecentlyDeleted = false

  @State private var recordings: [RecordingRecord] = []
  @State private var totalCount = 0
  @State private var query = ""
  @State private var isLoading = true
  @State private var requestGeneration = 0
  @State private var errorMessage: String?
  @State private var searchCoverage: String?
  @State private var editingRecording: RecordingRecord?

  private let pageSize = 20

  var body: some View {
    Group {
      if recordings.isEmpty, isLoading {
        ProgressView("Loading recordings…")
      } else if let errorMessage, recordings.isEmpty {
        ContentUnavailableView {
          Label("Could not load recordings", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try again") { Task { await reload() } }
        }
      } else if recordings.isEmpty {
        VStack {
          if query.isEmpty {
            ContentUnavailableView("No recordings yet", systemImage: "waveform")
          } else {
            ContentUnavailableView.search(text: query)
          }
          if let searchCoverage {
            Text(searchCoverage).font(.footnote).foregroundStyle(.secondary).padding()
          }
        }
      } else {
        List {
          if let searchCoverage, !query.isEmpty {
            Text(searchCoverage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .listRowBackground(Color.clear)
          }

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }

          ForEach(recordings) { recording in
            recordingRow(recording)
          }

          if query.isEmpty, recordings.count < totalCount {
            Button {
              Task { await loadNextPage() }
            } label: {
              if isLoading {
                ProgressView().frame(maxWidth: .infinity)
              } else {
                Text("Load more").frame(maxWidth: .infinity)
              }
            }
            .disabled(isLoading)
          }
        }
        .listStyle(.plain)
      }
    }
    .background(Color(uiColor: .systemBackground))
    .navigationTitle("All recordings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NavigationLink {
          AskRecordingsView().environment(model)
        } label: {
          Label("Ask recordings", systemImage: "text.bubble")
        }
        .accessibilityIdentifier("ask-recordings-link")
      }
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            isImporting = true
          } label: {
            Label("Import audio", systemImage: "square.and.arrow.down")
          }
          .accessibilityIdentifier("import-audio")
          Button {
            showsRecentlyDeleted = true
          } label: {
            Label("Recently deleted", systemImage: "trash")
          }
          .accessibilityIdentifier("recently-deleted")
        } label: {
          Label("More library actions", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("library-more")
      }
    }
    .navigationDestination(isPresented: $showsRecentlyDeleted) {
      RecentlyDeletedView().environment(model)
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      Task {
        await model.importAudioFiles(urls)
        await reload()
      }
    }
    .searchable(text: $query, prompt: "Search titles and local transcripts")
    .accessibilityIdentifier("recording-library")
    .task(id: "\(query)-\(model.libraryVersion)") {
      do {
        try await Task.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        await reload()
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
    .sheet(item: $editingRecording) { recording in
      RecordingTitleEditor(recording: recording) { updated in
        if let index = recordings.firstIndex(where: { $0.id == updated.id }) {
          recordings[index] = updated
        }
        if !query.isEmpty { Task { await reload() } }
      }
      .environment(\.locale, model.settings.language.locale)
      .presentationDetents([.medium])
    }
  }

  private func recordingRow(_ recording: RecordingRecord) -> some View {
    HStack(spacing: 12) {
      NavigationLink {
        RecordingDetailView(recording: recording).environment(model)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(recording.libraryDisplayTitle(language: model.settings.language))
            .font(.headline)
            .foregroundStyle(.primary)
          Text("\(libraryDuration(recording.duration)) · \(rowStatus(recording))")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let overview = recording.overview {
            Text(overview)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
      }
      .accessibilityIdentifier("library-recording-\(recording.id)")

      Button {
        editingRecording = recording
      } label: {
        Image(systemName: "pencil")
          .frame(minWidth: 44, minHeight: 44)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Edit recording title")
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if recording.canBeDeleted {
        Button(role: .destructive) {
          moveToTrash(recording)
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier("delete-recording-\(recording.id)")
      }
    }
  }

  private func rowStatus(_ recording: RecordingRecord) -> String {
    model.onDeviceProcessingRecordingIDs.contains(recording.id)
      ? model.settings.language.localized("Transcribing and summarizing…")
      : recording.libraryStatusLabel(language: model.settings.language)
  }

  private func moveToTrash(_ recording: RecordingRecord) {
    recordings.removeAll { $0.id == recording.id }
    Task {
      if await !model.moveToTrash(recording) { await reload() }
    }
  }

  @MainActor
  private func reload() async {
    requestGeneration += 1
    let generation = requestGeneration
    let requestedQuery = query
    isLoading = true
    errorMessage = nil
    defer { if generation == requestGeneration { isLoading = false } }
    do {
      let service = try RecordingLibraryService(layout: RecordingFileLayout())
      let normalized = requestedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.isEmpty {
        async let count = service.count()
        // Keeps what is already loaded, so a change does not jump back to the first page.
        async let firstPage = service.page(limit: max(pageSize, recordings.count), offset: 0)
        let (loadedCount, loadedPage) = try await (count, firstPage)
        try Task.checkCancellation()
        guard generation == requestGeneration, requestedQuery == query else { return }
        totalCount = loadedCount
        recordings = loadedPage
        searchCoverage = nil
      } else {
        let result = try await service.search(normalized)
        try Task.checkCancellation()
        guard generation == requestGeneration, requestedQuery == query else { return }
        recordings = result.recordings
        totalCount = result.recordings.count
        searchCoverage = coverageDescription(result)
      }
    } catch is CancellationError {
      return
    } catch {
      if generation == requestGeneration, requestedQuery == query { errorMessage = error.localizedDescription }
    }
  }

  @MainActor
  private func loadNextPage() async {
    guard !isLoading else { return }
    isLoading = true
    let generation = requestGeneration
    let requestedQuery = query
    defer { if generation == requestGeneration { isLoading = false } }
    do {
      let service = try RecordingLibraryService(layout: RecordingFileLayout())
      let next = try await service.page(limit: pageSize, offset: recordings.count)
      guard generation == requestGeneration, requestedQuery == query, query.isEmpty else { return }
      recordings.append(contentsOf: next)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func coverageDescription(_ result: RecordingLibrarySearchResult) -> String {
    var parts = [
      String(
        format: model.settings.language.localized("Searched local transcript text for %d recordings."),
        result.transcriptFilesSearched)
    ]
    if result.recordingsWithoutLocalTranscript > 0 {
      parts.append(
        String(
          format: model.settings.language.localized("%d recordings have no local transcript text."),
          result.recordingsWithoutLocalTranscript))
    }
    if !result.transcriptErrors.isEmpty {
      parts.append(
        String(
          format: model.settings.language.localized("Could not read local transcript text for %d recordings."),
          result.transcriptErrors.count))
    }
    return parts.joined(separator: " ")
  }
}

struct RecentlyDeletedView: View {
  @Environment(AppModel.self) private var model

  @State private var recordings: [RecordingRecord] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var selectedRecording: RecordingRecord?
  @State private var isDeleteAllPresented = false

  var body: some View {
    Group {
      if recordings.isEmpty, isLoading {
        ProgressView()
      } else if let errorMessage, recordings.isEmpty {
        ContentUnavailableView {
          Label("Could not load recordings", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try again") { Task { await reload() } }
        }
      } else if recordings.isEmpty {
        ContentUnavailableView("No recently deleted recordings", systemImage: "trash")
      } else {
        List {
          Section {
            ForEach(recordings) { recording in
              row(recording)
            }
          } footer: {
            VStack(alignment: .leading, spacing: 6) {
              Text("Recordings stay here for 30 days, then are permanently deleted.")
              if model.settings.hasLegacyS3Credentials {
                Text("Copies backed up to S3 earlier stay in your bucket.")
              }
            }
          }
        }
      }
    }
    .navigationTitle("Recently deleted")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      if !recordings.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button("Delete all", role: .destructive) { isDeleteAllPresented = true }
            .accessibilityIdentifier("delete-all-permanently")
        }
      }
    }
    .accessibilityIdentifier("recently-deleted-list")
    .task(id: model.libraryVersion) { await reload() }
    .confirmationDialog(
      selectedRecording?.libraryDisplayTitle(language: model.settings.language) ?? "",
      isPresented: selectedBinding,
      titleVisibility: .visible,
      presenting: selectedRecording
    ) { recording in
      Button("Recover") { Task { await model.restore(recording) } }
        .accessibilityIdentifier("recover-recording")
      Button("Delete permanently", role: .destructive) {
        Task { await model.deletePermanently([recording]) }
      }
      .accessibilityIdentifier("delete-recording-permanently")
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Permanently deleting a recording cannot be undone.")
    }
    .confirmationDialog(
      "Delete all recordings permanently?",
      isPresented: $isDeleteAllPresented,
      titleVisibility: .visible
    ) {
      Button("Delete all", role: .destructive) {
        Task { await model.deletePermanently(recordings) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Permanently deleting a recording cannot be undone.")
    }
  }

  private func row(_ recording: RecordingRecord) -> some View {
    Button {
      selectedRecording = recording
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(recording.libraryDisplayTitle(language: model.settings.language))
          .font(.headline)
          .foregroundStyle(.primary)
        Text("\(libraryDuration(recording.duration)) · \(daysLeft(recording))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("deleted-recording-\(recording.id)")
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      Button {
        Task { await model.restore(recording) }
      } label: {
        Label("Recover", systemImage: "arrow.uturn.backward")
      }
      .tint(.blue)
    }
  }

  private func daysLeft(_ recording: RecordingRecord) -> String {
    String(
      format: model.settings.language.localized("Days left: %d"),
      recording.daysUntilPermanentDeletion()
    )
  }

  private var selectedBinding: Binding<Bool> {
    Binding(
      get: { selectedRecording != nil },
      set: { if !$0 { selectedRecording = nil } }
    )
  }

  @MainActor
  private func reload() async {
    isLoading = true
    defer { isLoading = false }
    do {
      recordings = try await model.deletedRecordings()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct RecordingTitleEditor: View {
  @Environment(\.dismiss) private var dismiss
  let recording: RecordingRecord
  let onSaved: (RecordingRecord) -> Void

  @State private var title: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(recording: RecordingRecord, onSaved: @escaping (RecordingRecord) -> Void) {
    self.recording = recording
    self.onSaved = onSaved
    _title = State(initialValue: recording.resolvedTitle ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Recording title", text: $title)
          .textInputAutocapitalization(.sentences)
          .accessibilityIdentifier("recording-title-field")
        if let errorMessage {
          Text(errorMessage).font(.caption).foregroundStyle(.red)
        }
      }
      .navigationTitle("Edit title")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(isSaving)
            .accessibilityIdentifier("save-recording-title")
        }
      }
    }
  }

  @MainActor
  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let service = try RecordingLibraryService(layout: RecordingFileLayout())
      let updated = try await service.saveTitle(title, for: recording.id)
      onSaved(updated)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

extension RecordingRecord {
  func libraryDisplayTitle(language: AppLanguage) -> String {
    resolvedTitle ?? formattedStartDate(startedAt, language: language)
  }

  /// A recording still being captured or finished cannot be deleted.
  var canBeDeleted: Bool {
    ![.recording, .paused, .finishing].contains(status)
  }

  /// Whole days left in Recently Deleted, counting a partial day as one.
  func daysUntilPermanentDeletion(now: Date = Date()) -> Int {
    guard let deletedAt else { return 0 }
    let remaining = deletedAt.addingTimeInterval(RecordingStore.trashRetention)
      .timeIntervalSince(now)
    return max(0, Int((remaining / (24 * 60 * 60)).rounded(.up)))
  }

  func libraryStatusLabel(language: AppLanguage) -> String {
    storageStatusText(language: language)
  }
}

private func libraryDuration(_ interval: TimeInterval) -> String {
  let seconds = max(0, Int(interval.rounded(.down)))
  if seconds >= 3_600 {
    return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
  }
  return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
