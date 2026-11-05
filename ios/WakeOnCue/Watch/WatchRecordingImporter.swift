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

  @discardableResult
  static func stage(segmentURL: URL, metadata: WatchSegmentMetadata, root: URL? = nil) throws -> URL {
    let destination = try directory(for: metadata.sessionID, root: root)
      .appending(path: metadata.fileName)
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.moveItem(at: segmentURL, to: destination)
    } catch {
      // The importer may have just removed the empty folder, and this file is the only copy.
      _ = try directory(for: metadata.sessionID, root: root)
      try FileManager.default.moveItem(at: segmentURL, to: destination)
    }
    try RecordingFileLayout.protect(destination)
    return destination
  }

  static func stage(summary: WatchSessionSummary, root: URL? = nil) throws {
    let url = try directory(for: summary.sessionID, root: root).appending(path: "summary.json")
    let data = try WatchBridgeCoding.encode(summary)
    do {
      try data.write(to: url, options: [.atomic])
    } catch {
      // As with a segment: the importer may have just removed the folder, and the Watch will
      // not send this summary again.
      _ = try directory(for: summary.sessionID, root: root)
      try data.write(to: url, options: [.atomic])
    }
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

  /// The segments in a folder, or nil if it can't be read or holds anything else.
  static func segmentIndexes(in folder: URL) -> Set<Int>? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
      return nil
    }
    var indexes: Set<Int> = []
    for name in names where name != "summary.json" {
      guard name.hasPrefix("segment-"), name.hasSuffix(".m4a"),
        let index = Int(name.dropFirst("segment-".count).dropLast(".m4a".count))
      else { return nil }
      indexes.insert(index)
    }
    return indexes
  }

  /// Removes the folders of these recordings, e.g. late segments of permanently deleted ones.
  static func removeFolders(ofRecordings recordingIDs: Set<String>, root: URL? = nil) {
    guard !recordingIDs.isEmpty, let root = try? root ?? Self.root(),
      let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    else { return }
    for folder in folders {
      guard let sessionID = UUID(uuidString: folder.lastPathComponent),
        recordingIDs.contains(WatchSessionSummary.recordingID(for: sessionID))
      else { continue }
      try? FileManager.default.removeItem(at: folder)
    }
  }

  /// Folders holding segments but no summary, with the session each belongs to.
  static func foldersWithoutSummary(root: URL? = nil) throws -> [(sessionID: UUID, folder: URL)] {
    let root = try root ?? Self.root()
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .compactMap { folder in
        guard let sessionID = UUID(uuidString: folder.lastPathComponent),
          !FileManager.default.fileExists(atPath: folder.appending(path: "summary.json").path)
        else { return nil }
        return (sessionID, folder)
      }
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
    await removeLateSegments(root: root)
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
        if await !removeFolderIfDone(
          item.directory, recordingID: item.summary.recordingID, summaryWasRead: true)
        {
          // Without its summary the folder is not imported again each time the inbox changes.
          try? FileManager.default.removeItem(at: item.directory.appending(path: "summary.json"))
        }
      } catch {
        print("WakeOnCue could not import Watch recording \(item.summary.sessionID): \(error)")
      }
    }
    return imported
  }

  /// A segment delivered again after its recording was imported or deleted has no summary
  /// coming, so nothing else would remove it. Other folders wait.
  private func removeLateSegments(root: URL?) async {
    guard let folders = try? WatchSessionInbox.foldersWithoutSummary(root: root) else { return }
    for (sessionID, folder) in folders {
      let recordingID = WatchSessionSummary.recordingID(for: sessionID)
      await removeFolderIfDone(folder, recordingID: recordingID, summaryWasRead: false)
    }
  }

  /// The Watch drops its copy once a segment is delivered, so this folder may hold the only one.
  /// A completed recording can still lack segments, because an import may go ahead without them,
  /// so only segments that became chunks, or that belong to a deleted recording, can go.
  /// Removes only the files it checked: a segment or summary staged meanwhile keeps the folder.
  /// A summary is removed only by the caller that read it, because one can arrive first, into an
  /// empty folder, and the Watch does not send it again. Returns whether the folder is gone.
  @discardableResult
  private func removeFolderIfDone(
    _ folder: URL, recordingID: String, summaryWasRead: Bool
  ) async -> Bool {
    if (try? await store.wasPermanentlyDeleted(recordingID: recordingID)) == true {
      try? FileManager.default.removeItem(at: folder)
      return true
    }
    guard let segments = WatchSessionInbox.segmentIndexes(in: folder) else { return false }
    // An empty folder without a summary may be one a summary is being written into.
    guard summaryWasRead || !segments.isEmpty else { return false }
    if !segments.isEmpty {
      guard let recording = try? await store.recording(id: recordingID),
        recording.status == .completed,
        let chunks = try? await store.chunks(recordingID: recordingID),
        segments.isSubset(of: Set(chunks.map(\.index)))
      else { return false }
    }
    for index in segments {
      let name = WatchSegmentMetadata(
        sessionID: UUID(), index: index, startedAt: .distantPast, duration: 0
      ).fileName
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
    if summaryWasRead {
      try? FileManager.default.removeItem(at: folder.appending(path: "summary.json"))
    }
    // rmdir fails on a folder that is no longer empty, so a segment that just arrived stays.
    return rmdir(folder.path) == 0
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
