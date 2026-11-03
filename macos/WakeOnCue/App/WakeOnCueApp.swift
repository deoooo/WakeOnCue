import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private let hotKey = GlobalHotKey()
  private var keyMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await model.launch() }
    keyMonitor = PlaybackKeys.install(model: model)
    hotKey.register { [model] in Task { await model.recorder.togglePause() } }
    #if DEBUG
      DebugSnapshot.startIfRequested(model: model)
    #endif
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    model.recorder.turnOff()
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
