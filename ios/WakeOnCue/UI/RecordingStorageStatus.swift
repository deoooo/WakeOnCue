import Foundation
import WakeOnCueCore

extension RecordingRecord {
  /// Classifies persisted status using this record's own cloud metadata and current local files.
  /// This lookup never creates a recording directory or downloads an object.
  var storagePresentation: RecordingStatusPresentation {
    let sourceURL = URL(filePath: localAudioPath)
    let cachedM4AURL = sourceURL.deletingLastPathComponent()
      .appending(path: "WakeOnCue-\(id).m4a")
    let fileManager = FileManager.default
    let hasLocalFile = fileManager.fileExists(atPath: sourceURL.path)
      || fileManager.fileExists(atPath: cachedM4AURL.path)

    return RecordingStatusPresentation.classify(
      recordingStatus: status.rawValue,
      uploadStatus: uploadStatus.rawValue,
      metadata: metadata,
      localFileExists: hasLocalFile
    )
  }

  func storageStatusText(language: AppLanguage) -> String {
    storagePresentation.storageStatusText(language: language)
  }
}

extension RecordingStatusPresentation {
  func storageStatusText(language: AppLanguage) -> String {
    let local = localFileStatusText(language: language)
    guard let cloud = cloudBackupStatusText(language: language) else { return local }
    return "\(local) · \(cloud)"
  }

  func localFileStatusText(language: AppLanguage) -> String {
    switch localFile {
    case .notStarted: language.localized("Recordings save on this iPhone")
    case .saving: language.localized("Saving on this iPhone")
    case .saved: language.localized("Saved on this iPhone")
    case .unavailable: language.localized("Not available on this iPhone")
    case .unknown: language.localized("Local file status unknown")
    }
  }

  func cloudBackupStatusText(language: AppLanguage) -> String? {
    switch cloudBackup {
    case .notRequested: nil
    case .pending: language.localized("Backup pending")
    case .synced: language.localized("Backup complete")
    case .failed: language.localized("Backup needs attention")
    case .abandoned: language.localized("Kept on this iPhone")
    }
  }
}
