import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  let model = AppModel()
  private let hotKey = GlobalHotKey()
  private var keyMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    Task { await model.launch() }
    keyMonitor = PlaybackKeys.install(model: model)
    if !AppModel.replayOnly && !AppModel.viewOnly {
      hotKey.register { [model] in Task { await model.recorder.togglePause() } }
    }
    #if DEBUG
      DebugSnapshot.startIfRequested(model: model)
    #endif
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    model.recorder.quit()
  }

  /// "继续录音" on the still-paused reminder, or clicking the reminder itself.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.notification.request.content.categoryIdentifier == Recorder.pauseReminderCategory else { return }
    let resume = response.actionIdentifier == Recorder.resumeAction
    await MainActor.run {
      if resume {
        Task { await self.model.recorder.resume() }
      } else {
        NSApp.activate()
      }
    }
  }

  /// Shows the reminder even while the app is active.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

@main
struct WakeOnCueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Window("WakeOnCue", id: "main") {
      MainWindow()
        .environment(delegate.model)
    }
    .defaultSize(width: 1240, height: 820)
    .windowResizability(.contentMinSize)
    .commands { DayCommands(model: delegate.model) }

    Settings {
      SettingsView().environment(delegate.model)
    }

    MenuBarExtra {
      MenuBarContent().environment(delegate.model)
    } label: {
      MenuBarIcon(state: delegate.model.recorder.state)
    }
    .menuBarExtraStyle(.window)
  }
}
