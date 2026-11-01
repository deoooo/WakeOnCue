import AVFoundation
import CryptoKit
import Foundation
import WakeOnCueCore

struct RecordingRecoveryService: Sendable {
  struct Outcome: Sendable {
    var finished: [RecordingRecord] = []
    var firstError: String?
  }

  let fileLayout: RecordingFileLayout

  /// Finishes each interrupted recording on its own, so one damaged recording cannot hold back
  /// the others or the rest of app startup.
  func finishInterrupted(
    _ recordingIDs: [String],
    store: RecordingStore,
    prepareAudio: @Sendable (String) async -> Void
  ) async -> Outcome {
    var outcome = Outcome()
    for recordingID in recordingIDs {
      do {
        try await recoverUnindexedChunks(recordingID: recordingID, store: store)
      } catch {
        print("WakeOnCue could not scan chunks of \(recordingID): \(error.localizedDescription)")
      }
      do {
        let chunks = try await store.chunks(recordingID: recordingID)
        if !chunks.isEmpty { await prepareAudio(recordingID) }
        try await store.completeLocally(
          recordingID: recordingID,
          duration: chunks.reduce(0) { $0 + $1.duration }
        )
        outcome.finished.append(try await store.recording(id: recordingID))
      } catch {
        outcome.firstError = outcome.firstError ?? error.localizedDescription
      }
    }
    return outcome
  }

  /// Recordings an older version left waiting on a backup are finished on this iPhone instead.
  /// Failed recordings are only finished when they still have audio to show for it.
  func finishRetiredUploads(
    store: RecordingStore,
    prepareAudio: @Sendable (String) async -> Void
  ) async -> Outcome {
    var outcome = Outcome()
    var offset = 0
    while true {
      let page: [RecordingRecord]
      do {
        page = try await store.recordings(limit: 100, offset: offset)
      } catch {
        outcome.firstError = outcome.firstError ?? error.localizedDescription
        return outcome
      }
      for recording in page where [.uploading, .failed].contains(recording.status) {
        do {
          let chunks = try await store.chunks(recordingID: recording.id)
          if recording.status == .failed, chunks.isEmpty,
            !FileManager.default.fileExists(atPath: recording.localAudioPath)
          {
            continue
          }
          if !chunks.isEmpty { await prepareAudio(recording.id) }
          try await store.completeLocally(recordingID: recording.id, duration: recording.duration)
          outcome.finished.append(try await store.recording(id: recording.id))
        } catch {
          outcome.firstError = outcome.firstError ?? error.localizedDescription
        }
      }
      if page.count < 100 { return outcome }
      offset += page.count
    }
  }

  /// Indexes chunks that were written but never saved to the database. A chunk the process was
  /// killed while writing cannot be read, and is skipped; the source file still holds its audio.
  func recoverUnindexedChunks(
    recordingID: String,
    store: RecordingStore
  ) async throws {
    let indexed = try await store.chunks(recordingID: recordingID)
    let knownIndices = Set(indexed.map(\.index))
    let chunkDirectory = try fileLayout.directory(for: recordingID)
      .appending(path: "chunks", directoryHint: .isDirectory)
    let files = try FileManager.default.contentsOfDirectory(
      at: chunkDirectory,
      includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "m4a" }
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      // Chunk numbers start at 1, but imports once wrote their only chunk as 0.
      guard let fileIndex = Int(file.deletingPathExtension().lastPathComponent) else { continue }
      let index = max(fileIndex, 1)
      guard !knownIndices.contains(index) else { continue }
      do {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.05 else { continue }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let values = try file.resourceValues(forKeys: [.creationDateKey])
        try await store.insertChunk(
          ChunkRecord(
            id: "\(recordingID)_\(String(format: "%06d", index))",
            recordingID: recordingID,
            index: index,
            localPath: file.path,
            checksum: checksum,
            size: Int64(data.count),
            startedAt: values.creationDate ?? Date(),
            duration: duration
          ),
          enqueueUpload: false
        )
      } catch {
        print("WakeOnCue skipped unreadable chunk \(file.lastPathComponent): \(error.localizedDescription)")
      }
    }
  }
}
