import AVFoundation
import Foundation
import WakeOnCueCore

struct RecordingAudioAssembler: Sendable {
  let fileLayout: RecordingFileLayout

  func assemble(recordingID: String, chunks: [ChunkRecord]) async throws -> URL {
    let outputURL = try fileLayout.downloadedAudioURL(recordingID: recordingID)
    if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
    guard !chunks.isEmpty else { throw RecordingAudioAssemblerError.noAudio }

    let composition = AVMutableComposition()
    guard
      let compositionTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else { throw RecordingAudioAssemblerError.cannotCreateTrack }
    var cursor = CMTime.zero
    for chunk in chunks.sorted(by: { $0.index < $1.index }) {
      let asset = AVURLAsset(url: URL(filePath: chunk.localPath))
      guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw RecordingAudioAssemblerError.invalidChunk(chunk.index)
      }
      let duration = try await asset.load(.duration)
      try compositionTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: track,
        at: cursor
      )
      cursor = cursor + duration
    }

    guard let exporter = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetAppleM4A
    ) else { throw RecordingAudioAssemblerError.exportUnavailable }
    try? FileManager.default.removeItem(at: outputURL)
    try await exporter.export(to: outputURL, as: .m4a)
    try RecordingFileLayout.protect(outputURL)
    return outputURL
  }
}

enum RecordingAudioAssemblerError: LocalizedError {
  case noAudio
  case cannotCreateTrack
  case invalidChunk(Int)
  case exportUnavailable

  var errorDescription: String? {
    switch self {
    case .noAudio: AppLanguage.localized("No playable audio chunks were found.")
    case .cannotCreateTrack:
      AppLanguage.localized("Could not create the combined audio track.")
    case .invalidChunk(let index):
      String(
        format: AppLanguage.localized("Audio chunk %d is not playable."),
        locale: AppLanguage.current.locale,
        index
      )
    case .exportUnavailable: AppLanguage.localized("M4A export is unavailable.")
    }
  }
}
