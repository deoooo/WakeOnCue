import Foundation
import WakeOnCueCore

struct RecordingFileLayout: Sendable {
  let root: URL

  init(fileManager: FileManager = .default) throws {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    root = applicationSupport.appending(path: "RecordingData", directoryHint: .isDirectory)
    try Self.prepareDirectory(root, fileManager: fileManager)
  }

  var databaseURL: URL {
    root.appending(path: "recordings.sqlite")
  }

  func directory(for recordingID: String) throws -> URL {
    let directory =
      root
      .appending(path: "recordings", directoryHint: .isDirectory)
      .appending(path: recordingID, directoryHint: .isDirectory)
    try Self.prepareDirectory(directory, fileManager: .default)
    try Self.prepareDirectory(
      directory.appending(path: "chunks", directoryHint: .isDirectory), fileManager: .default)
    try Self.prepareDirectory(
      directory.appending(path: "queue", directoryHint: .isDirectory), fileManager: .default)
    return directory
  }

  func sourceAudioURL(recordingID: String) throws -> URL {
    try directory(for: recordingID).appending(path: "source.caf")
  }

  func chunkURL(recordingID: String, index: Int) throws -> URL {
    try directory(for: recordingID)
      .appending(path: "chunks", directoryHint: .isDirectory)
      .appending(path: String(format: "%06d.m4a", index))
  }

  func downloadedAudioURL(recordingID: String) throws -> URL {
    try directory(for: recordingID).appending(path: "WakeOnCue-\(recordingID).m4a")
  }

  func transcriptURL(recordingID: String) throws -> URL {
    try directory(for: recordingID).appending(path: "transcript.json")
  }

  func createPayload(recording: RecordingRecord) throws -> URL {
    let url = try directory(for: recording.id)
      .appending(path: "queue", directoryHint: .isDirectory)
      .appending(path: "create.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(CreateRecordingPayload(recording: recording)).write(
      to: url, options: [.atomic])
    try Self.protect(url)
    return url
  }

  func emptyPayload(recordingID: String, name: String) throws -> URL {
    let url = try directory(for: recordingID)
      .appending(path: "queue", directoryHint: .isDirectory)
      .appending(path: "\(name).json")
    try Data().write(to: url, options: [.atomic])
    try Self.protect(url)
    return url
  }

  private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  static func protect(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }
}
