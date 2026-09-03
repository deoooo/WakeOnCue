import Foundation
import WakeOnCueCore

struct RecordingStorageMaintenance: Sendable {
  let fileLayout: RecordingFileLayout

  func removeUploadedSourceFiles(
    recording: RecordingRecord,
    chunks: [ChunkRecord]
  ) throws {
    let recordingDirectory = try fileLayout.directory(for: recording.id).standardizedFileURL
    try removeOwnedFile(URL(filePath: recording.localAudioPath), under: recordingDirectory)
    for chunk in chunks {
      try removeOwnedFile(URL(filePath: chunk.localPath), under: recordingDirectory)
    }

    let chunksDirectory = recordingDirectory.appending(path: "chunks", directoryHint: .isDirectory)
    let queueDirectory = recordingDirectory.appending(path: "queue", directoryHint: .isDirectory)
    try removeOwnedFile(chunksDirectory, under: recordingDirectory)
    try removeOwnedFile(queueDirectory, under: recordingDirectory)
  }

  func removeExpiredFinalAudio(recordingID: String) throws {
    let recordingDirectory = try fileLayout.directory(for: recordingID).standardizedFileURL
    let finalAudio = try fileLayout.downloadedAudioURL(recordingID: recordingID)
    try removeOwnedFile(finalAudio, under: recordingDirectory)
  }

  private func removeOwnedFile(_ url: URL, under recordingDirectory: URL) throws {
    let candidate = url.standardizedFileURL
    let directoryPath =
      recordingDirectory.path.hasSuffix("/")
      ? recordingDirectory.path : recordingDirectory.path + "/"
    guard candidate.path.hasPrefix(directoryPath) else {
      throw RecordingStorageMaintenanceError.pathOutsideRecordingDirectory(candidate.path)
    }
    guard FileManager.default.fileExists(atPath: candidate.path) else { return }
    try FileManager.default.removeItem(at: candidate)
  }
}

enum RecordingStorageMaintenanceError: LocalizedError {
  case pathOutsideRecordingDirectory(String)

  var errorDescription: String? {
    switch self {
    case .pathOutsideRecordingDirectory(let path):
      "Refused to remove a file outside the recording directory: \(path)"
    }
  }
}
