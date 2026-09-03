import Foundation
import WakeOnCueCore

struct RecordingAudioFileProvider: Sendable {
  let fileLayout: RecordingFileLayout

  func file(
    for recording: RecordingRecord,
    chunks: [ChunkRecord],
    s3Configuration: S3Configuration?
  ) async throws -> URL {
    let cached = try fileLayout.downloadedAudioURL(recordingID: recording.id)
    if FileManager.default.fileExists(atPath: cached.path) { return cached }

    let allChunksAvailable =
      !chunks.isEmpty
      && chunks.allSatisfy { FileManager.default.fileExists(atPath: $0.localPath) }
    if allChunksAvailable {
      return try await RecordingAudioAssembler(fileLayout: fileLayout).assemble(
        recordingID: recording.id,
        chunks: chunks
      )
    }

    let local = URL(filePath: recording.localAudioPath)
    if FileManager.default.fileExists(atPath: local.path) { return local }

    guard recording.status == .completed, recording.uploadStatus == .completed,
      let s3Configuration
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try await S3StorageClient.downloadRecording(
      recordingID: recording.id,
      configuration: s3Configuration,
      destinationURL: cached
    )
  }
}
