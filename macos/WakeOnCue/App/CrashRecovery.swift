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

  static func registerIfNeeded() {
    let service = SMAppService.agent(plistName: plistName)
    guard service.status != .enabled else { return }
    do {
      try service.register()
      logger.notice("Registered the crash watchdog")
    } catch {
      // A development build may be unsigned or moved; recording still works without it.
      logger.notice("Could not register the crash watchdog: \(error.localizedDescription, privacy: .public)")
    }
  }
}
