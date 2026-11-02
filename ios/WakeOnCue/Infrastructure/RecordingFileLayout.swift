import Foundation
import WakeOnCueCore

struct RecordingFileLayout: Sendable {
  let root: URL

  init(root: URL) throws {
    self.root = root
    try Self.prepareDirectory(root, fileManager: .default)
  }

  init(fileManager: FileManager = .default) throws {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    #if DEBUG && targetEnvironment(simulator)
      let environment = ProcessInfo.processInfo.environment
      let directoryName = environment["WAKEONCUE_EXPERIENCE_FIXTURES"] == "1"
        ? (environment["WAKEONCUE_EXPERIENCE_UNREADABLE_TRANSCRIPT"] == "1"
          ? "ExperienceUnreadableTestData" : "ExperienceTestData") : "RecordingData"
    #else
      let directoryName = "RecordingData"
    #endif
    root = applicationSupport.appending(path: directoryName, directoryHint: .isDirectory)
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

  /// Removes everything stored for a recording. Removing files that are already gone succeeds.
  func removeFiles(recordingID: String) throws {
    guard !recordingID.isEmpty, recordingID != ".", recordingID != "..",
      !recordingID.contains("/")
    else {
      throw RecordingStoreError.invalidData("Invalid recording identifier")
    }
    let directory =
      root
      .appending(path: "recordings", directoryHint: .isDirectory)
      .appending(path: recordingID, directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
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

  func summaryURL(recordingID: String) throws -> URL {
    try directory(for: recordingID).appending(path: "summary.json")
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
