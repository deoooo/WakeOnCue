import Foundation

public enum RecordingStateError: Error, Equatable, LocalizedError, Sendable {
  case invalidTransition(from: RecordingStatus, to: RecordingStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidTransition(let from, let to):
      "Invalid recording transition from \(from.rawValue) to \(to.rawValue)"
    }
  }
}

public enum RecordingStateMachine {
  private static let transitions: [RecordingStatus: Set<RecordingStatus>] = [
    .ready: [.recording],
    .recording: [.paused, .finishing, .failed],
    .paused: [.recording, .finishing, .failed],
    .finishing: [.uploading, .completed, .failed],
    .uploading: [.completed, .failed],
    .completed: [],
    .failed: [.uploading],
  ]

  public static func validate(from: RecordingStatus, to: RecordingStatus) throws {
    guard from != to else { return }
    guard transitions[from, default: []].contains(to) else {
      throw RecordingStateError.invalidTransition(from: from, to: to)
    }
  }
}
