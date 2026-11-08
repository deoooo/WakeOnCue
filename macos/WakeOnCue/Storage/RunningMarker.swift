import Darwin
import Foundation

/// A file that says the app is running, with its process ID. The app writes it at launch and
/// removes it when it quits normally, so a marker whose process is gone means the app crashed,
/// was force-quit or lost power. The crash watchdog (`wakeoncue watchdog`, run by launchd every
/// 30 seconds) relaunches the app then.
///
/// The earlier watchdog was a launchd job with `KeepAlive`, which only restarts a process launchd
/// started itself. The app is normally opened from Finder or as a login item, so on 2026-11-07 a
/// crash went unnoticed for 27 hours.
nonisolated enum RunningMarker {
  static var url: URL { Store.rootDirectory.appending(path: "running") }
  /// Times the watchdog relaunched the app, to stop after a crash loop.
  static var relaunchLogURL: URL { Store.rootDirectory.appending(path: "watchdog-relaunches") }

  static func write(pid: Int32 = getpid()) {
    try? FileManager.default.createDirectory(at: Store.rootDirectory, withIntermediateDirectories: true)
    try? String(pid).write(to: url, atomically: true, encoding: .utf8)
  }

  /// Removes the marker if this process wrote it. A second copy that exits at launch must not
  /// remove the running app's marker.
  static func removeIfOwned(pid: Int32 = getpid()) {
    guard read() == pid else { return }
    try? FileManager.default.removeItem(at: url)
  }

  static func read() -> Int32? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Whether `pid` is a running WakeOnCue app, not a process that reused the number.
  static func isAppProcess(_ pid: Int32) -> Bool {
    guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return path.hasSuffix(".app/Contents/MacOS/WakeOnCue")
  }

  enum Decision: Equatable {
    /// Running, or quit normally.
    case nothing
    case relaunch
    /// Crashed again right after being relaunched several times: leave it closed.
    case givingUp
  }

  /// At most this many relaunches within `loopWindow`; more is a crash loop.
  static let loopLimit = 3
  static let loopWindow: TimeInterval = 10 * 60

  static func decide(markerPID: Int32?, isRunning: Bool, recentRelaunches: [Date], now: Date) -> Decision {
    guard markerPID != nil, !isRunning else { return .nothing }
    let recent = recentRelaunches.filter { now.timeIntervalSince($0) < loopWindow }
    return recent.count >= loopLimit ? .givingUp : .relaunch
  }

  static func relaunches() -> [Date] {
    guard let text = try? String(contentsOf: relaunchLogURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { Double($0).map(Date.init(timeIntervalSince1970:)) }
  }

  static func recordRelaunch(at date: Date) {
    let kept = relaunches().filter { date.timeIntervalSince($0) < loopWindow } + [date]
    try? kept.map { String($0.timeIntervalSince1970) }.joined(separator: "\n")
      .write(to: relaunchLogURL, atomically: true, encoding: .utf8)
  }
}
