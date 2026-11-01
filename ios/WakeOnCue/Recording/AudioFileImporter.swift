@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import WakeOnCueCore

/// Turns an audio file from Files, Voice Memos or another recorder into a local recording.
@MainActor
struct AudioFileImporter {
  static let sourceMetadataKey = "source"
  static let sourceMetadataValue = "imported_file"

  let store: RecordingStore
  let fileLayout: RecordingFileLayout

  func importFile(at source: URL) async throws -> RecordingRecord {
    let accessing = source.startAccessingSecurityScopedResource()
    defer { if accessing { source.stopAccessingSecurityScopedResource() } }

    let recordingID =
      "rec_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    let chunkURL = try fileLayout.chunkURL(recordingID: recordingID, index: 1)
    let asset = AVURLAsset(url: source)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else { throw AudioCaptureError.converterUnavailable }
    try await export.export(to: chunkURL, as: .m4a)
    try RecordingFileLayout.protect(chunkURL)

    let seconds = try await AVURLAsset(url: chunkURL).load(.duration).seconds
    let duration = seconds.isFinite ? max(0, seconds) : 0
    let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let endedAt = values?.contentModificationDate ?? values?.creationDate ?? .now
    let startedAt = endedAt.addingTimeInterval(-duration)
    let recording = RecordingRecord(
      id: recordingID,
      createdAt: endedAt,
      startedAt: startedAt,
      status: .finishing,
      localAudioPath: chunkURL.path,
      uploadStatus: .pending,
      deviceModel: "ImportedFile",
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "unknown",
      metadata: [
        Self.sourceMetadataKey: Self.sourceMetadataValue,
        RecordingRecord.titleMetadataKey: source.deletingPathExtension().lastPathComponent,
      ]
    )
    try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
    let data = try Data(contentsOf: chunkURL, options: .mappedIfSafe)
    try await store.insertChunk(
      ChunkRecord(
        id: UUID().uuidString,
        recordingID: recordingID,
        index: 1,
        localPath: chunkURL.path,
        checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        size: Int64(data.count),
        startedAt: startedAt,
        duration: duration
      ),
      enqueueUpload: false
    )
    _ = try await RecordingAudioAssembler(fileLayout: fileLayout).assemble(
      recordingID: recordingID,
      chunks: try await store.chunks(recordingID: recordingID)
    )
    try await store.completeLocally(recordingID: recordingID, duration: duration, endedAt: endedAt)
    return try await store.recording(id: recordingID)
  }
}
