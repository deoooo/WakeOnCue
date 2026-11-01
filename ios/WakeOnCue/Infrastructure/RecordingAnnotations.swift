import Foundation
import Observation
import WakeOnCueCore

struct RecordingBookmark: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let position: TimeInterval
  var title: String?
  let createdAt: Date
  /// Length of a marked span such as "the last 2 minutes"; `nil` for a point bookmark.
  var duration: TimeInterval?
  var tag: RecordingMarkTag?

  init(
    id: UUID = UUID(),
    position: TimeInterval,
    title: String? = nil,
    createdAt: Date = Date(),
    duration: TimeInterval? = nil,
    tag: RecordingMarkTag? = nil
  ) {
    self.id = id
    self.position = max(0, position)
    self.title = Self.normalized(title)
    self.createdAt = createdAt
    self.duration = duration.map { max(0, $0) }
    self.tag = tag
  }

  var displayTitle: String {
    title ?? tag?.localizedTitle ?? RecordingTranscriptExporter.playbackTimestamp(position)
  }

  /// "00:10" for a point, "00:10–02:10" for a span.
  var timeRangeText: String {
    let start = RecordingTranscriptExporter.playbackTimestamp(position)
    guard let duration, duration > 0 else { return start }
    return "\(start)–\(RecordingTranscriptExporter.playbackTimestamp(position + duration))"
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

struct RecordingAnnotations: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int = currentVersion
  var bookmarks: [RecordingBookmark] = []
  var speakerAliases: [String: String] = [:]
  var updatedAt: Date = Date()
}

enum RecordingAnnotationsError: LocalizedError {
  case unavailable
  case unsupportedVersion

  var errorDescription: String? {
    switch self {
    case .unavailable:
      AppLanguage.localized("Recording annotations storage is unavailable.")
    case .unsupportedVersion:
      AppLanguage.localized("These annotations were created by a newer version of WakeOnCue.")
    }
  }
}

/// Main-actor ownership keeps every view observing this service in sync immediately.
@MainActor
@Observable
final class RecordingAnnotationsService {
  static let shared = RecordingAnnotationsService(makeURL: { recordingID in
    let layout = try RecordingFileLayout()
    return try layout.directory(for: recordingID).appending(path: "annotations.json")
  })

  private(set) var annotationsByRecordingID: [String: RecordingAnnotations] = [:]
  private(set) var errorsByRecordingID: [String: String] = [:]

  private let makeURL: (String) throws -> URL
  private let fileManager: FileManager

  init(fileLayout: RecordingFileLayout, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    makeURL = { recordingID in
      try fileLayout.directory(for: recordingID).appending(path: "annotations.json")
    }
  }

  /// This initializer is intentionally available for isolated persistence tests.
  init(rootDirectory: URL, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    makeURL = { recordingID in
      rootDirectory
        .appending(path: "recordings", directoryHint: .isDirectory)
        .appending(path: recordingID, directoryHint: .isDirectory)
        .appending(path: "annotations.json")
    }
  }

  private init(
    makeURL: @escaping (String) throws -> URL,
    fileManager: FileManager = .default
  ) {
    self.makeURL = makeURL
    self.fileManager = fileManager
  }

  func annotations(for recordingID: String) -> RecordingAnnotations {
    if let cached = annotationsByRecordingID[recordingID] { return cached }
    do {
      let loaded = try read(recordingID: recordingID)
      annotationsByRecordingID[recordingID] = loaded
      errorsByRecordingID[recordingID] = nil
      return loaded
    } catch {
      errorsByRecordingID[recordingID] = error.localizedDescription
      let empty = RecordingAnnotations()
      annotationsByRecordingID[recordingID] = empty
      return empty
    }
  }

  @discardableResult
  func reload(recordingID: String) throws -> RecordingAnnotations {
    let loaded = try read(recordingID: recordingID)
    annotationsByRecordingID[recordingID] = loaded
    errorsByRecordingID[recordingID] = nil
    return loaded
  }

  @discardableResult
  func addBookmark(
    recordingID: String,
    position: TimeInterval,
    title: String? = nil,
    duration: TimeInterval? = nil,
    tag: RecordingMarkTag? = nil
  ) throws -> RecordingBookmark {
    let bookmark = RecordingBookmark(
      position: position, title: title, duration: duration, tag: tag)
    try mutate(recordingID: recordingID) { annotations in
      annotations.bookmarks.append(bookmark)
      annotations.bookmarks.sort {
        if $0.position == $1.position { return $0.createdAt < $1.createdAt }
        return $0.position < $1.position
      }
    }
    return bookmark
  }

  func deleteBookmark(recordingID: String, bookmarkID: UUID) throws {
    try mutate(recordingID: recordingID) { annotations in
      annotations.bookmarks.removeAll { $0.id == bookmarkID }
    }
  }

  func renameBookmark(recordingID: String, bookmarkID: UUID, title: String?) throws {
    try mutate(recordingID: recordingID) { annotations in
      guard let index = annotations.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
        return
      }
      let existing = annotations.bookmarks[index]
      annotations.bookmarks[index] = RecordingBookmark(
        id: existing.id,
        position: existing.position,
        title: title,
        createdAt: existing.createdAt,
        duration: existing.duration,
        tag: existing.tag
      )
    }
  }

  func setBookmarkTag(recordingID: String, bookmarkID: UUID, tag: RecordingMarkTag?) throws {
    try mutate(recordingID: recordingID) { annotations in
      guard let index = annotations.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
        return
      }
      annotations.bookmarks[index].tag = tag
    }
  }

  func setSpeakerAlias(recordingID: String, clusterID: String, alias: String?) throws {
    let normalized = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try mutate(recordingID: recordingID) { annotations in
      if normalized.isEmpty {
        annotations.speakerAliases.removeValue(forKey: clusterID)
      } else {
        annotations.speakerAliases[clusterID] = normalized
      }
    }
  }

  func removeCachedAnnotations(recordingID: String) {
    annotationsByRecordingID[recordingID] = nil
    errorsByRecordingID[recordingID] = nil
  }

  private func mutate(
    recordingID: String,
    change: (inout RecordingAnnotations) -> Void
  ) throws {
    // A failed read must not turn into a successful write of an empty replacement.
    var value = try read(recordingID: recordingID)
    change(&value)
    value.updatedAt = Date()
    try write(value, recordingID: recordingID)
    annotationsByRecordingID[recordingID] = value
    errorsByRecordingID[recordingID] = nil
  }

  private func read(recordingID: String) throws -> RecordingAnnotations {
    let url = try makeURL(recordingID)
    guard fileManager.fileExists(atPath: url.path) else { return RecordingAnnotations() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let annotations = try decoder.decode(RecordingAnnotations.self, from: Data(contentsOf: url))
    guard annotations.version == RecordingAnnotations.currentVersion else {
      throw RecordingAnnotationsError.unsupportedVersion
    }
    return annotations
  }

  private func write(_ annotations: RecordingAnnotations, recordingID: String) throws {
    let url = try makeURL(recordingID)
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: directory.path
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(annotations).write(to: url, options: [.atomic])
    try RecordingFileLayout.protect(url)
  }
}

extension RecordingMarkTag {
  var localizedTitle: String {
    switch self {
    case .todo: AppLanguage.localized("To-do")
    case .important: AppLanguage.localized("Important")
    case .idea: AppLanguage.localized("Idea")
    }
  }
}

/// A name typed for this recording wins, then a recognized saved voice, then the
/// processor's anonymous label.
func effectiveSpeakerName(
  _ speaker: RealtimeSpeaker?,
  aliases: [String: String],
  personNames: [String: String] = [:],
  unknownSpeakerName: String = "Unknown speaker"
) -> String {
  guard let speaker else { return unknownSpeakerName }
  if let alias = aliases[speaker.clusterID]?.trimmingCharacters(in: .whitespacesAndNewlines),
    !alias.isEmpty
  {
    return alias
  }
  if let personID = speaker.personID, let name = personNames[personID] { return name }
  let original = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  return original.isEmpty ? unknownSpeakerName : original
}

enum RecordingTranscriptExportFormat: String, CaseIterable, Sendable {
  case plainText = "txt"
  case srt
}

enum RecordingTranscriptExporter {
  static func plainText(
    transcript: [RealtimeTranscriptEvent],
    speakerAliases: [String: String],
    personNames: [String: String] = [:],
    unknownSpeakerName: String = "Unknown speaker"
  ) -> String {
    sorted(transcript).map { segment in
      let speaker = effectiveSpeakerName(
        segment.speaker,
        aliases: speakerAliases,
        personNames: personNames,
        unknownSpeakerName: unknownSpeakerName
      )
      return
        "[\(playbackTimestamp(TimeInterval(segment.startMilliseconds) / 1_000))] \(speaker): \(segment.text)"
    }.joined(separator: "\n")
  }

  static func srt(
    transcript: [RealtimeTranscriptEvent],
    speakerAliases: [String: String],
    personNames: [String: String] = [:],
    unknownSpeakerName: String = "Unknown speaker"
  ) -> String {
    sorted(transcript).enumerated().map { index, segment in
      let speaker = effectiveSpeakerName(
        segment.speaker,
        aliases: speakerAliases,
        personNames: personNames,
        unknownSpeakerName: unknownSpeakerName
      )
      let start = max(0, segment.startMilliseconds)
      let end = max(start, segment.endMilliseconds)
      return
        "\(index + 1)\n\(srtTimestamp(start)) --> \(srtTimestamp(end))\n\(speaker): \(segment.text)"
    }.joined(separator: "\n\n")
  }

  static func write(
    recording: RecordingRecord,
    transcript: [RealtimeTranscriptEvent],
    speakerAliases: [String: String],
    personNames: [String: String] = [:],
    format: RecordingTranscriptExportFormat,
    directory: URL = FileManager.default.temporaryDirectory,
    unknownSpeakerName: String = "Unknown speaker"
  ) throws -> RecordingShareItem {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(
      path: "\(exportBaseName(recording: recording)).\(format.rawValue)")
    let content: String
    switch format {
    case .plainText:
      content = plainText(
        transcript: transcript,
        speakerAliases: speakerAliases,
        personNames: personNames,
        unknownSpeakerName: unknownSpeakerName
      )
    case .srt:
      content = srt(
        transcript: transcript,
        speakerAliases: speakerAliases,
        personNames: personNames,
        unknownSpeakerName: unknownSpeakerName
      )
    }
    try Data(content.utf8).write(to: url, options: [.atomic])
    return RecordingShareItem(url: url)
  }

  static func playbackTimestamp(_ position: TimeInterval) -> String {
    let totalSeconds = max(0, Int(position.rounded(.down)))
    if totalSeconds >= 3_600 {
      return String(
        format: "%d:%02d:%02d",
        totalSeconds / 3_600,
        totalSeconds % 3_600 / 60,
        totalSeconds % 60
      )
    }
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  static func srtTimestamp(_ milliseconds: Int) -> String {
    let value = max(0, milliseconds)
    let hours = value / 3_600_000
    let minutes = value % 3_600_000 / 60_000
    let seconds = value % 60_000 / 1_000
    let remainder = value % 1_000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
  }

  private static func sorted(_ transcript: [RealtimeTranscriptEvent]) -> [RealtimeTranscriptEvent] {
    transcript.sorted {
      if $0.startMilliseconds == $1.startMilliseconds { return $0.id < $1.id }
      return $0.startMilliseconds < $1.startMilliseconds
    }
  }

  private static func exportBaseName(recording: RecordingRecord) -> String {
    let fallback = recording.startedAt.formatted(
      Date.FormatStyle()
        .year().month(.twoDigits).day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        .locale(Locale(identifier: "en_US_POSIX"))
    )
    let source = recording.title ?? "Recording \(fallback)"
    let disallowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
    let components = source.components(separatedBy: disallowed).filter { !$0.isEmpty }
    let safeName = components.joined(separator: "-")
    return safeName.isEmpty ? "Recording-\(recording.id)" : safeName
  }
}
