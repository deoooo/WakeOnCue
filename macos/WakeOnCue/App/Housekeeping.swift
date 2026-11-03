import Foundation
import ServiceManagement

extension AppModel {
  var todayRecordedSeconds: TimeInterval {
    _ = store.revision
    let start = Calendar.current.startOfDay(for: .now)
    return store.segments(overlapping: DateInterval(start: start, end: .now))
      .filter { $0.channel == .microphone }
      .reduce(0) { $0 + min($1.end, .now).timeIntervalSince(max($1.start, start)) }
  }

  /// "删除刚才的录音…": the last N minutes, with the same confirmation as deleting an hour.
  func deleteRecent(minutes: Int) {
    let interval = DateInterval(start: .now.addingTimeInterval(-Double(minutes) * 60), end: .now)
    let spoken = store.sentences(in: interval).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60
    confirmDelete(interval, spokenMinutes: Int(spoken.rounded()), title: "刚才 \(minutes) 分钟")
  }

  /// Runs at launch and every hour: audio past its retention is removed (transcripts stay),
  /// text past its retention too, and deleted ranges older than 30 days are erased for good.
  func startHousekeeping() {
    Task {
      while !Task.isCancelled {
        cleanUp()
        try? await Task.sleep(for: .seconds(3_600))
      }
    }
  }

  func cleanUp() {
    let now = Date()
    if preferences.audioRetentionDays > 0 {
      let cutoff = now.addingTimeInterval(-Double(preferences.audioRetentionDays) * 86_400)
      for segment in store.segments(endingBefore: cutoff) {
        try? FileManager.default.removeItem(at: Store.audioDirectory.appending(path: segment.path))
        store.removeSegment(id: segment.id)
      }
    }
    if preferences.textRetentionDays > 0 {
      let cutoff = now.addingTimeInterval(-Double(preferences.textRetentionDays) * 86_400)
      store.purge(DateInterval(start: .distantPast, end: cutoff))
    }
    for mark in store.marks() where mark.kind == .deleted && now.timeIntervalSince(mark.createdAt) > 30 * 86_400 {
      store.purge(DateInterval(start: mark.start, end: mark.end))
      store.removeMark(id: mark.id)
    }
  }

  /// "立即清空…" in storage settings.
  func emptyRecentlyDeleted() {
    for mark in store.marks() where mark.kind == .deleted {
      store.purge(DateInterval(start: mark.start, end: mark.end))
      store.removeMark(id: mark.id)
    }
  }

  var launchesAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
  }
}
