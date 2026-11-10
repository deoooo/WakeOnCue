import Foundation
import OSLog
import WakeOnCueCore

/// Conversations synced from the paired Mac are kept as ordinary recordings on this iPhone, so
/// Review, Search, questions and playback work on them unchanged. See docs/sync-protocol.md.
enum MacConversation {
  /// Same key as `WatchRecordingImporter.sourceMetadataKey`.
  static let sourceKey = "source"
  /// `RecordingRecord.metadata["source"]` of a conversation from the Mac.
  static let sourceValue = "mac"
  static let conversationKey = "mac_conversation"
  static let dayKey = "mac_day"
  static let digestKey = "mac_digest"
  static let sourcesKey = "mac_sources"
  /// Set on this iPhone's own recordings once the Mac's conversation includes them: they stop
  /// showing on their own.
  static let includedInKey = "included_in_mac_conversation"

  static func recordingID(for conversationID: String) -> String { "mac_\(conversationID)" }

  static func isFromMac(_ recording: RecordingRecord) -> Bool {
    recording.metadata[MacConversation.sourceKey] == sourceValue
  }

  static func conversationID(of recording: RecordingRecord) -> String? {
    isFromMac(recording) ? recording.metadata[conversationKey] : nil
  }

  /// Whether Review, Search and questions list it: not when the Mac's version replaces it.
  static func isListed(_ recording: RecordingRecord) -> Bool {
    recording.metadata[includedInKey] == nil
  }

  /// This iPhone's recording ID for one the Mac names by the ID it was sent under.
  static func localRecordingID(_ device: SyncProtocol.DeviceRecording) -> String {
    guard device.source == "watch", let session = UUID(uuidString: device.recordingID) else {
      return device.recordingID
    }
    return WatchSessionSummary.recordingID(for: session)
  }
}

/// Where the Mac's audio is kept, chosen in Settings.
enum MacAudioPlacement: String, CaseIterable, Identifiable, Sendable {
  /// Downloaded to this iPhone and kept on the Mac.
  case both
  /// Left on the Mac; played from it while on the same network.
  case macOnly

  static let preferenceKey = "mac.audio-placement"
  var id: String { rawValue }

  static var current: MacAudioPlacement {
    get { MacAudioPlacement(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .both }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
  }
}

/// What this iPhone knows of the Mac's library, and edits waiting to go to it.
enum MacLibraryState {
  private struct File: Codable {
    var days: [String: String] = [:]
    var edits: [SyncProtocol.LibraryEdit] = []
  }

  private static var url: URL {
    let folder = URL.applicationSupportDirectory.appending(path: "MacLibrary", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: "state.json")
  }

  private static let lock = NSLock()

  private static func read() -> File {
    guard let data = try? Data(contentsOf: url) else { return File() }
    return (try? JSONDecoder.sync.decode(File.self, from: data)) ?? File()
  }

  private static func update(_ change: (inout File) -> Void) {
    lock.withLock {
      var file = read()
      change(&file)
      if let data = try? JSONEncoder.sync.encode(file) { try? data.write(to: url, options: .atomic) }
    }
  }

  /// Day → digest of every day received.
  static var days: [String: String] { lock.withLock { read().days } }

  static func setDigest(_ digest: String, day: String) { update { $0.days[day] = digest } }

  static var pendingEdits: [SyncProtocol.LibraryEdit] { lock.withLock { read().edits } }

  static func enqueue(_ kind: SyncProtocol.LibraryEdit.Kind, recording: RecordingRecord, value: String? = nil) {
    guard let conversationID = MacConversation.conversationID(of: recording) else { return }
    let edit = SyncProtocol.LibraryEdit(
      id: UUID().uuidString.lowercased(), conversationID: conversationID, start: recording.startedAt,
      end: recording.startedAt.addingTimeInterval(max(1, recording.duration)), kind: kind, value: value, madeAt: .now)
    update { file in
      // A newer rename replaces one not yet sent.
      if kind == .rename { file.edits.removeAll { $0.kind == .rename && $0.conversationID == conversationID } }
      file.edits.append(edit)
    }
  }

  static func removeEdits(ids: [String]) {
    let sent = Set(ids)
    update { $0.edits.removeAll { sent.contains($0.id) } }
  }

  /// After unpairing, a Mac paired later starts from scratch.
  static func reset() { update { $0 = File() } }
}

/// Applies days received from the Mac to the recordings on this iPhone.
@MainActor
struct MacLibraryImporter {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue", category: "MacLibrary")
  /// Conversations this recent are summarized on this iPhone as soon as they arrive.
  static let summarizeWithin: TimeInterval = 3 * 86_400

  let store: RecordingStore
  let layout: RecordingFileLayout
  let library: RecordingLibraryService

  /// Returns the recordings that should be summarized now.
  func apply(_ day: SyncProtocol.LibraryDay, language: AppLanguage) async throws -> [RecordingRecord] {
    var toSummarize: [RecordingRecord] = []
    var kept: Set<String> = []
    for conversation in day.conversations {
      let id = MacConversation.recordingID(for: conversation.id)
      kept.insert(id)
      if let recording = try await apply(conversation, recordingID: id, day: day.day, language: language),
        recording.startedAt > Date().addingTimeInterval(-Self.summarizeWithin)
      {
        toSummarize.append(recording)
      }
      for device in conversation.deviceRecordings {
        let local = MacConversation.localRecordingID(device)
        if let own = try? await store.recording(id: local), own.metadata[MacConversation.includedInKey] == nil {
          _ = try? await store.updateRecordingMetadata(recordingID: local, values: [MacConversation.includedInKey: conversation.id])
        }
      }
    }
    // Gone from the Mac's day: deleted or made private there, or merged into another conversation.
    if let start = ConversationDay.start(day.day) {
      let interval = DateInterval(start: start, duration: 86_400 + 3_600)
      for recording in try await library.recordings(startedIn: interval, includingUnlisted: true)
      where MacConversation.isFromMac(recording) && recording.metadata[MacConversation.dayKey] == day.day
        && !kept.contains(recording.id)
      {
        try? await library.moveToTrash(recordingID: recording.id)
        try? await library.deletePermanently(recordingID: recording.id)
      }
    }
    MacLibraryState.setDigest(day.digest, day: day.day)
    return toSummarize
  }

  /// Creates or updates one conversation. Returns it when its text is new or changed.
  private func apply(
    _ conversation: SyncProtocol.LibraryConversation, recordingID: String, day: String, language: AppLanguage
  ) async throws -> RecordingRecord? {
    let duration = max(1, conversation.end.timeIntervalSince(conversation.start))
    let metadata = [
      MacConversation.sourceKey: MacConversation.sourceValue,
      MacConversation.conversationKey: conversation.id,
      MacConversation.dayKey: day,
      MacConversation.digestKey: conversation.digest,
      MacConversation.sourcesKey: conversation.sources.joined(separator: ","),
    ]
    let existing: RecordingRecord?
    do {
      existing = try await store.recording(id: recordingID)
    } catch RecordingStoreError.notFound {
      // Deleted for good on this iPhone: the delete is on its way to the Mac.
      if try await store.wasPermanentlyDeleted(recordingID: recordingID) { return nil }
      existing = nil
    }
    if let existing {
      // In Recently Deleted here; the Mac has not applied the delete yet.
      if existing.isDeleted { return nil }
      guard existing.metadata[MacConversation.digestKey] != conversation.digest else { return nil }
      try await store.updateRecordingMetadata(recordingID: recordingID, values: metadata)
      try await store.updateDuration(recordingID: recordingID, duration: duration)
    } else {
      let recording = RecordingRecord(
        id: recordingID, createdAt: conversation.end, startedAt: conversation.start, status: .recording,
        localAudioPath: try layout.sourceAudioURL(recordingID: recordingID).path, uploadStatus: .pending,
        deviceModel: "Mac", appVersion: "mac", metadata: metadata)
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
      try await store.completeLocally(recordingID: recordingID, duration: duration, endedAt: conversation.end)
    }
    if let title = conversation.title, (try? await store.recording(id: recordingID))?.resolvedTitle != title {
      _ = try await store.updateRecordingTitle(recordingID: recordingID, title: title)
    }
    try writeTranscript(conversation, recordingID: recordingID, language: language)
    // The text changed, so the old audio no longer matches its times.
    if existing != nil, let audio = try? layout.downloadedAudioURL(recordingID: recordingID) {
      try? FileManager.default.removeItem(at: audio)
    }
    return try await store.recording(id: recordingID)
  }

  private func writeTranscript(
    _ conversation: SyncProtocol.LibraryConversation, recordingID: String, language: AppLanguage
  ) throws {
    let events = conversation.sentences.map { sentence in
      RealtimeTranscriptEvent(
        recordingID: recordingID, segmentID: "mac_\(sentence.id)", revision: 1,
        startMilliseconds: max(0, Int(sentence.start.timeIntervalSince(conversation.start) * 1_000)),
        endMilliseconds: max(0, Int(sentence.end.timeIntervalSince(conversation.start) * 1_000)),
        text: sentence.text, isFinal: true, speaker: Self.speaker(sentence, language: language))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let url = try layout.transcriptURL(recordingID: recordingID)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(events).write(to: url, options: .atomic)
    try RecordingFileLayout.protect(url)
  }

  static func speaker(_ sentence: SyncProtocol.LibrarySentence, language: AppLanguage) -> RealtimeSpeaker {
    if let name = sentence.name, !name.isEmpty {
      return RealtimeSpeaker(clusterID: "mac-\(name)", displayName: name)
    }
    if sentence.speaker == "me" {
      return RealtimeSpeaker(clusterID: "mac-me", personID: RealtimeSpeaker.selfPersonID, displayName: "Me")
    }
    return RealtimeSpeaker(clusterID: "mac-other", displayName: language.localized("Someone else"))
  }

  /// Mac conversations whose audio is not on this iPhone yet, newest first.
  func recordingsNeedingAudio(limit: Int = 50) async throws -> [RecordingRecord] {
    var found: [RecordingRecord] = []
    var offset = 0
    while found.count < limit {
      let page = try await store.recordings(limit: 200, offset: offset)
      for recording in page where MacConversation.isFromMac(recording) {
        guard let url = try? layout.downloadedAudioURL(recordingID: recording.id),
          !FileManager.default.fileExists(atPath: url.path)
        else { continue }
        found.append(recording)
      }
      if page.count < 200 { break }
      offset += 200
    }
    return Array(found.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
  }
}

/// "yyyy-MM-dd" day keys in this iPhone's time zone.
enum ConversationDay {
  static func start(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}
