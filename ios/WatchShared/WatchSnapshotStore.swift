import Foundation

/// Keeps the Watch-side recording state where the complications can read it.
public enum WatchSnapshotStore {
  public static let appGroup = "group.com.deoooo.WakeOnCue"
  public static let statusWidgetKind = "com.deoooo.WakeOnCue.watch.status"
  public static let captureWidgetKind = "com.deoooo.WakeOnCue.watch.capture"
  public static let captureURL = URL(string: "wakeoncue://watch/capture-recent")!

  private static let snapshotKey = "watch.phone-snapshot"
  private static let watchRecordingStartKey = "watch.recording-started-at"

  public static func save(_ snapshot: WatchRecordingSnapshot) {
    guard let data = try? WatchBridgeCoding.encode(snapshot) else { return }
    defaults.set(data, forKey: snapshotKey)
  }

  public static func load() -> WatchRecordingSnapshot {
    guard let data = defaults.data(forKey: snapshotKey),
      let snapshot = try? WatchBridgeCoding.decode(WatchRecordingSnapshot.self, from: data)
    else { return .idle }
    return snapshot
  }

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
