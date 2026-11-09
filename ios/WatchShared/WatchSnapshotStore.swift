import Foundation

/// Keeps the Watch recording state where the complications can read it.
public enum WatchSnapshotStore {
  public static let appGroup = "group.com.deoooo.WakeOnCue"
  public static let statusWidgetKind = "com.deoooo.WakeOnCue.watch.status"

  private static let watchRecordingStartKey = "watch.recording-started-at"

  /// Start of a recording running on the Watch itself, for the complications.
  public static var watchRecordingStartedAt: Date? {
    get {
      let value = defaults.double(forKey: watchRecordingStartKey)
      return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
    set {
      if let newValue {
        defaults.set(newValue.timeIntervalSince1970, forKey: watchRecordingStartKey)
      } else {
        defaults.removeObject(forKey: watchRecordingStartKey)
      }
    }
  }

  private static var defaults: UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }
}
