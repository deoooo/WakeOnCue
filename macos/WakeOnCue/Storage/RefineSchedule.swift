import Foundation

/// When a sentence whose re-transcription failed is tried again. Kept apart from `Refiner` so the
/// rules can be tested without loading a model.
nonisolated enum RefineSchedule {
  /// One try plus three retries.
  static let maxAttempts = 4
  /// Wait this long after a sentence ends, so its audio is on disk.
  static let settle: TimeInterval = 8
  /// Only sentences this recent are looked at again.
  static let maximumAge: TimeInterval = 7 * 86_400

  /// Seconds until the next try after `attempt` failures, or nil when no tries are left.
  static func retryDelay(after attempt: Int) -> TimeInterval? {
    switch attempt {
    case ...0: 0
    case 1: 60
    case 2: 600
    case 3: 3_600
    default: nil
    }
  }

  static func nextTry(after attempt: Int, now: Date = .now) -> Date? {
    retryDelay(after: attempt).map { now.addingTimeInterval($0) }
  }
}
