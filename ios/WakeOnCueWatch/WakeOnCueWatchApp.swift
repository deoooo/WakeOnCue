import SwiftUI

@main
struct WakeOnCueWatchApp: App {
  @State private var model = WatchModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WatchHomeView()
        .environment(model)
        .onOpenURL { url in
          Task { await model.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
          WatchDiagnostics.logBattery("scene \(phase) watchRecording=\(model.isWatchRecording)")
        }
    }
    .backgroundTask(.watchConnectivity) {
      await WatchSessionClient.shared.waitForPendingContent()
    }
  }
}
