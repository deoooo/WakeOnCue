import Foundation
import OSLog
import ServiceManagement

/// Keeps the app alive after a crash without relaunching it after a normal quit.
///
/// macOS LaunchAgents registered with `SMAppService` support `KeepAlive` with
/// `SuccessfulExit = false`: a normal `NSApp.terminate` exits with status 0 and stays closed,
/// while a crash or force-kill is restarted. The plist is copied into the app bundle at
/// `Contents/Library/LaunchAgents` during the build.
enum CrashRecovery {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "CrashRecovery")
  static let plistName = "com.deoooo.WakeOnCue.watchdog.plist"
  private static let label = "com.deoooo.WakeOnCue.watchdog"

  static func registerIfNeeded() {
    let service = SMAppService.agent(plistName: plistName)
    // A previous version of the app may have marked the service enabled in ServiceManagement's
    // database while the launchd job itself is gone (for example after booting it out while
    // debugging). Check the actual job, not just the database status.
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
