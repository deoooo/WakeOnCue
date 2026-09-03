import AVFoundation
import CryptoKit
import Foundation
import WakeOnCueCore

struct RecordingRecoveryService: Sendable {
  let fileLayout: RecordingFileLayout

  func recoverUnindexedChunks(
    recordingID: String,
    store: RecordingStore,
    enqueueUpload: Bool = true
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
      guard let index = Int(file.deletingPathExtension().lastPathComponent),
        !knownIndices.contains(index)
      else { continue }
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
        enqueueUpload: enqueueUpload
      )
    }
  }
}
