import CoreFoundation
import Foundation

final class RecordingCommandObserver: @unchecked Sendable {
  private let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      pointer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<RecordingCommandObserver>
          .fromOpaque(observer)
          .takeUnretainedValue()
          .handler()
      },
      SharedRecordingState.commandNotification as CFString,
      nil,
      .deliverImmediately
    )
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(SharedRecordingState.commandNotification as CFString),
      nil
    )
  }
}
