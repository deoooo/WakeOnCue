import Foundation

/// A semantic, presentation-ready view of the independent recording services.
///
/// This type deliberately accepts persisted raw values so it can be shared by the app and
/// widget extension without coupling either target to a particular model implementation.
public struct RecordingStatusPresentation: Equatable, Sendable {
  public enum CaptureState: Equatable, Sendable {
    case ready
    case recording
    case paused
    case finishing
    case finalized
    case failed
  }

  public enum LocalFileState: Equatable, Sendable {
    case notStarted
    case saving
    case saved
    case unavailable
    case unknown
  }

  public enum CloudBackupState: Equatable, Sendable {
    case notRequested
    case pending
    case synced
    case failed
    case abandoned
  }

  /// Transcription is intentionally independent from capture and storage state.
  public enum TranscriptionState: Equatable, Sendable {
    case notRequested
    case connecting
    case waiting
    case live
    case offline
    case completed
    case failed
  }

  public let capture: CaptureState
  public let localFile: LocalFileState
  public let cloudBackup: CloudBackupState
  public let transcription: TranscriptionState

  public static func classify(
    recordingStatus: String,
    uploadStatus: String,
    metadata: [String: String] = [:],
    localFileExists: Bool? = nil,
    transcription: TranscriptionState = .notRequested
  ) -> Self {
    let phase = recordingStatus.uppercased()
    let upload = uploadStatus.uppercased()
    let cloudWasConfigured = metadata.contains { key, value in
      key.hasPrefix("s3.") && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let cloudWasAbandoned = truthy(metadata["cloud_sync_abandoned"])

    let capture: CaptureState = switch phase {
    case "RECORDING": .recording
    case "PAUSED": .paused
    case "FINISHING": .finishing
    case "UPLOADING", "COMPLETED": .finalized
    case "FAILED": .failed
    default: .ready
    }

    let localFile: LocalFileState = switch phase {
    case "RECORDING", "PAUSED", "FINISHING": .saving
    case "UPLOADING", "COMPLETED": localFileExists == false ? .unavailable : .saved
    case "FAILED":
      switch localFileExists {
      case true: .saved
      case false: .unavailable
      case nil: .unknown
      }
    default: .notStarted
    }

    let cloudBackup: CloudBackupState
    if cloudWasAbandoned {
      cloudBackup = .abandoned
    } else if !cloudWasConfigured {
      cloudBackup = .notRequested
    } else if phase == "COMPLETED" && upload == "COMPLETED" {
      cloudBackup = .synced
    } else if upload == "FAILED" {
      cloudBackup = .failed
    } else {
      cloudBackup = .pending
    }

    return Self(
      capture: capture,
      localFile: localFile,
      cloudBackup: cloudBackup,
      transcription: transcription
    )
  }

  /// A reduced classifier for Live Activity state, where persisted record metadata is unavailable.
  public static func classifyActivity(
    phase: String,
    cloudWasConfigured: Bool,
    transcription: TranscriptionState = .notRequested
  ) -> Self {
    let normalizedPhase = phase.uppercased()
    let uploadStatus: String
    switch normalizedPhase {
    case "COMPLETED": uploadStatus = "COMPLETED"
    case "FAILED": uploadStatus = "FAILED"
    default: uploadStatus = "PENDING"
    }
    return classify(
      recordingStatus: normalizedPhase,
      uploadStatus: uploadStatus,
      metadata: cloudWasConfigured ? ["s3.bucket": "configured"] : [:],
      transcription: transcription
    )
  }

  private static func truthy(_ value: String?) -> Bool {
    guard let value else { return false }
    return ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}
