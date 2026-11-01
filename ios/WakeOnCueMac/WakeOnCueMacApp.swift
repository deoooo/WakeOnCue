import AppKit
import SwiftUI

@main
struct WakeOnCueMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
  private var model: MacAppModel { delegate.model }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      Image(systemName: model.recorder.isRecording ? "record.circle.fill" : "waveform")
        .accessibilityLabel(Text("WakeOnCue"))
    }
    .menuBarExtraStyle(.window)

    Window(Text("Live Transcript"), id: WindowID.transcript) {
      TranscriptWindow(model: model)
    }
    .defaultSize(width: 420, height: 520)
    .windowResizability(.contentMinSize)
  }
}

enum WindowID {
  static let transcript = "transcript"
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  let model = MacAppModel()

  func applicationWillTerminate(_ notification: Notification) {
    // Never leave the Python Gateway or processor running after the app quits.
    model.host.terminateChildren()
  }
}
