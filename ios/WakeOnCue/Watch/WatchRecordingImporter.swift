import AVFoundation
import CryptoKit
import Foundation
import WakeOnCueCore

/// Landing area for recordings made on the Watch: one folder per recording holding its
/// `segment-NNNN.m4a` files and, once the Watch stopped, `summary.json`. Segments and the summary
/// travel independently and can arrive in any order.
enum WatchSessionInbox {
  struct Item: Sendable {
    let summary: WatchSessionSummary
    let directory: URL
    let segments: [Int: URL]
  }

  /// A summary whose segments are still missing after this long is imported with what arrived.
  static let incompleteImportDelay: TimeInterval = 24 * 60 * 60

  static func root(fileManager: FileManager = .default) throws -> URL {
    let directory = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appending(path: "WatchInbox/sessions", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func directory(for sessionID: UUID, root: URL? = nil) throws -> URL {
    let directory = try (root ?? Self.root())
      .appending(path: sessionID.uuidString.lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func stage(segmentURL: URL, metadata: WatchSegmentMetadata, root: URL? = nil) throws {
    let destination = try directory(for: metadata.sessionID, root: root)
      .appending(path: metadata.fileName)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: segmentURL, to: destination)
    try RecordingFileLayout.protect(destination)
  }

  static func stage(summary: WatchSessionSummary, root: URL? = nil) throws {
    let url = try directory(for: summary.sessionID, root: root).appending(path: "summary.json")
    try WatchBridgeCoding.encode(summary).write(to: url, options: [.atomic])
    try RecordingFileLayout.protect(url)
  }

  static func readyItems(root: URL? = nil, now: Date = Date()) throws -> [Item] {
    let root = try root ?? Self.root()
    let folders = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    return folders.compactMap { folder in
      let summaryURL = folder.appending(path: "summary.json")
      guard let data = try? Data(contentsOf: summaryURL),
        let summary = try? WatchBridgeCoding.decode(WatchSessionSummary.self, from: data)
      else { return nil }
      var segments: [Int: URL] = [:]
      for index in 0..<summary.segmentCount {
        let name = WatchSegmentMetadata(
          sessionID: summary.sessionID, index: index + 1, startedAt: .distantPast, duration: 0
        ).fileName
        let url = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) { segments[index + 1] = url }
      }
      let complete = segments.count == summary.segmentCount
      let stagedAt = (try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? now
      guard complete || now.timeIntervalSince(stagedAt) > incompleteImportDelay else { return nil }
      return Item(summary: summary, directory: folder, segments: segments)
    }.sorted { $0.summary.startedAt < $1.summary.startedAt }
  }
}

/// Turns a Watch recording whose pieces have all arrived into an ordinary, locally completed
/// recording: one chunk per segment, the Watch bookmarks, and the assembled M4A.
@MainActor
struct WatchRecordingImporter {
  static let sourceMetadataKey = "source"
  static let sourceMetadataValue = "apple_watch"

  let store: RecordingStore
  let fileLayout: RecordingFileLayout
  let annotations: RecordingAnnotationsService

  /// Assembles every Watch recording whose pieces have all arrived. Returns new recording IDs.
  func importPendingSessions(root: URL? = nil) async -> [String] {
    let items: [WatchSessionInbox.Item]
    do {
      items = try WatchSessionInbox.readyItems(root: root)
    } catch {
      print("WakeOnCue could not read Watch recordings: \(error.localizedDescription)")
      return []
    }
    var imported: [String] = []
    for item in items {
      do {
        if let recordingID = try await importSession(item) { imported.append(recordingID) }
        try? FileManager.default.removeItem(at: item.directory)
      } catch {
        print("WakeOnCue could not import Watch recording \(item.summary.sessionID): \(error)")
      }
    }
    return imported
  }

  private func importSession(_ item: WatchSessionInbox.Item) async throws -> String? {
    let summary = item.summary
    let recordingID = summary.recordingID
    // The Watch re-sends anything it has no acknowledgement for, even after the user deleted it.
    guard try await !store.wasPermanentlyDeleted(recordingID: recordingID) else { return nil }
    guard !item.segments.isEmpty else { return nil }
    if let existing = try? await store.recording(id: recordingID), existing.status == .completed {
      return recordingID
    }

    var measured: [(index: Int, url: URL, duration: TimeInterval)] = []
    for (index, source) in item.segments.sorted(by: { $0.key < $1.key }) {
      let chunkURL = try fileLayout.chunkURL(recordingID: recordingID, index: index)
      if !FileManager.default.fileExists(atPath: chunkURL.path) {
        try FileManager.default.copyItem(at: source, to: chunkURL)
        try RecordingFileLayout.protect(chunkURL)
      }
      let seconds = try await AVURLAsset(url: chunkURL).load(.duration).seconds
      measured.append((index, chunkURL, seconds.isFinite ? max(0, seconds) : 0))
    }
    let duration = measured.reduce(0) { $0 + $1.duration }

    if (try? await store.recording(id: recordingID)) == nil {
      let recording = RecordingRecord(
        id: recordingID,
        createdAt: summary.endedAt,
        startedAt: summary.startedAt,
        status: .finishing,
        localAudioPath: measured[0].url.path,
        uploadStatus: .pending,
        deviceModel: "AppleWatch",
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "unknown",
        metadata: [
          Self.sourceMetadataKey: Self.sourceMetadataValue,
          "watch_end_reason": summary.endReason,
        ]
      )
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
    }
    let existingIndexes = Set(try await store.chunks(recordingID: recordingID).map(\.index))
    var cursor = summary.startedAt
    for segment in measured {
      defer { cursor = cursor.addingTimeInterval(segment.duration) }
      guard !existingIndexes.contains(segment.index) else { continue }
      let data = try Data(contentsOf: segment.url, options: .mappedIfSafe)
      try await store.insertChunk(
        ChunkRecord(
          id: UUID().uuidString,
          recordingID: recordingID,
          index: segment.index,
          localPath: segment.url.path,
          checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
          size: Int64(data.count),
          startedAt: cursor,
          duration: segment.duration
        ),
        enqueueUpload: false
      )
    }
    _ = try await RecordingAudioAssembler(fileLayout: fileLayout).assemble(
      recordingID: recordingID,
      chunks: try await store.chunks(recordingID: recordingID)
    )
    if annotations.annotations(for: recordingID).bookmarks.isEmpty {
      for bookmark in summary.bookmarks where bookmark.position < duration {
        try annotations.addBookmark(
          recordingID: recordingID,
          position: bookmark.position,
          duration: bookmark.duration.map { min($0, duration - bookmark.position) },
          tag: bookmark.tag
        )
      }
    }
    try await store.completeLocally(
      recordingID: recordingID, duration: duration, endedAt: summary.endedAt)
    return recordingID
  }
}
