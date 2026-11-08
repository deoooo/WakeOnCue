import Foundation
import OSLog
import ServiceManagement

/// Relaunches the app after a crash, a force-quit or a power loss, never after a normal quit.
///
/// A launchd agent runs `wakeoncue watchdog` (the command-line tool in Contents/Helpers) every
/// 30 seconds. The app keeps `RunningMarker` while it runs and removes it when it quits
/// normally; a marker whose process is gone means it did not quit normally, so the watchdog
/// opens it again (three times in ten minutes at most, then it gives up on a crash loop).
///
/// This replaces a `KeepAlive` agent that launched the app executable itself: launchd only
/// restarts processes it started, so the app opened from Finder or as a login item was never
/// watched, and a crash on 2026-11-07 went unnoticed for 27 hours.
enum CrashRecovery {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "CrashRecovery")
  static let plistName = "com.deoooo.WakeOnCue.crashwatch.plist"
  private static let label = "com.deoooo.WakeOnCue.crashwatch"
  private static let oldPlistName = "com.deoooo.WakeOnCue.watchdog.plist"

  static func registerIfNeeded() {
    let old = SMAppService.agent(plistName: oldPlistName)
    if old.status != .notRegistered {
      try? old.unregister()
      logger.notice("Unregistered the old KeepAlive watchdog")
    }
    let service = SMAppService.agent(plistName: plistName)
    // ServiceManagement may say enabled while the launchd job is gone (for example after booting
    // it out while debugging). Check the actual job, not just the database status.
    if service.status == .enabled, isJobLoaded() { return }
    do {
      if service.status == .enabled { try? service.unregister() }
      try service.register()
      logger.notice("Registered the crash watchdog")
    } catch {
      // A development build may be unsigned or moved; recording still works without it.
      logger.notice("Could not register the crash watchdog: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func isJobLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/\(label)"]
    let null = FileHandle(forWritingAtPath: "/dev/null")
    process.standardOutput = null
    process.standardError = null
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
