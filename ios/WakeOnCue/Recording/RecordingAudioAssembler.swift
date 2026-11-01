import AVFoundation
import Foundation
import UIKit
import WakeOnCueCore

struct RecordingAudioAssembler: Sendable {
  let fileLayout: RecordingFileLayout

  func assemble(recordingID: String, chunks: [ChunkRecord]) async throws -> URL {
    let outputURL = try fileLayout.downloadedAudioURL(recordingID: recordingID)
    if await Self.isPlayable(outputURL) { return outputURL }
    guard !chunks.isEmpty else { throw RecordingAudioAssemblerError.noAudio }
    // Exporting hours of audio can outlast a background wake (for example a Watch delivery),
    // so ask for time to finish; an export cut short only ever leaves the partial file behind.
    let backgroundTime = await BackgroundTime.begin(name: "Assemble \(recordingID)")
    defer { Task { await backgroundTime.end() } }

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
    // Export next to the final file and move it into place only once complete, so an existing
    // output always means a finished export.
    let partialURL = outputURL.deletingPathExtension().appendingPathExtension("partial.m4a")
    try? FileManager.default.removeItem(at: partialURL)
    try await exporter.export(to: partialURL, as: .m4a)
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.moveItem(at: partialURL, to: outputURL)
    try RecordingFileLayout.protect(outputURL)
    return outputURL
  }

  /// Files written before exports were made atomic can be empty or truncated.
  static func isPlayable(_ url: URL) async -> Bool {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
      let duration = try? await AVURLAsset(url: url).load(.duration)
    else { return false }
    return duration.seconds.isFinite && duration.seconds > 0
  }
}

/// Extra execution time for work that must not stop halfway when the app leaves the foreground.
/// The token ends itself if the system's allowance runs out, which UIKit requires.
@MainActor
private final class BackgroundTime {
  private var identifier = UIBackgroundTaskIdentifier.invalid

  static func begin(name: String) -> BackgroundTime {
    let token = BackgroundTime()
    token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak token] in
      token?.end()
    }
    return token
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
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
