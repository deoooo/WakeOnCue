import Foundation
import WatchKit

/// Debug-only timeline of Watch capture, used to see how long recording survives with the
/// screen off and what it costs in battery. Read it from the device with `devicectl device copy from` (Documents/diagnostics.log).
enum WatchDiagnostics {
  #if DEBUG
    private static let lock = NSLock()
    private static let url = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appending(path: "diagnostics.log")
    private static let format = Date.ISO8601FormatStyle(timeZone: .current)
  #endif

  static func log(_ message: @autoclosure () -> String) {
    #if DEBUG
      let line = "\(Date().formatted(format)) \(message())\n"
      lock.withLock {
        // Daily use keeps this on for days; start over rather than grow without bound.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
          try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
          handle.seekToEndOfFile()
          handle.write(Data(line.utf8))
          try? handle.close()
        } else {
          try? Data(line.utf8).write(to: url)
        }
      }
    #endif
  }

  @MainActor
  static func logBattery(_ context: String) {
    #if DEBUG
      let device = WKInterfaceDevice.current()
      device.isBatteryMonitoringEnabled = true
      log("\(context) battery=\(Int(device.batteryLevel * 100))%")
    #endif
  }
}
