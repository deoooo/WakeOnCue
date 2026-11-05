import BackgroundTasks
import SwiftUI

@main
struct WakeOnCueApp: App {
  @State private var model = AppModel.bootstrap()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .task {
          #if DEBUG && targetEnvironment(simulator)
            do { try await ExperienceFixtures.prepareIfRequested() }
            catch { model.errorMessage = "Experience fixture setup failed: \(error.localizedDescription)" }
            // Test hook: queues an audio file for the paired Mac, as a Watch segment would be.
            if let path = ProcessInfo.processInfo.environment["WAKEONCUE_TEST_MAC_OUTBOX"] {
              let id = "watch-simtest-\(Int(Date().timeIntervalSince1970))-0001"
              try? MacOutbox.enqueue(
                file: URL(fileURLWithPath: path), id: id, source: "watch", recordingID: "simtest", index: 1,
                startedAt: Date().addingTimeInterval(-300), duration: 5)
            }
            // Test hook: a Watch recording summary with one tagged "记下刚才" mark, as if the
            // Watch had just sent it.
            if ProcessInfo.processInfo.environment["WAKEONCUE_TEST_MAC_MARKS"] != nil {
              let summary = WatchSessionSummary(
                sessionID: UUID(), startedAt: Date().addingTimeInterval(-300), endedAt: Date().addingTimeInterval(-60),
                segmentCount: 0,
                bookmarks: [WatchSessionBookmark(position: 120, duration: 120, tag: .important)])
              try? MacOutbox.enqueue(marks: MacOutbox.marks(of: summary))
            }
          #endif
          await model.start()
        }
        .onOpenURL { url in
          Task { await model.handle(url: url) }
        }
        .onChange(of: scenePhase) {
          switch scenePhase {
          case .active: Task { await model.macUploader.sync() }
          case .background: MacSyncTask.schedule()
          default: break
          }
        }
    }
    // Background refresh forwards what is still waiting when the app is not opened for a while.
    .backgroundTask(.appRefresh(MacSyncTask.identifier)) {
      await model.macUploader.sync()
      MacSyncTask.schedule()
    }
  }
}

enum MacSyncTask {
  static let identifier = "com.deoooo.WakeOnCue.mac-sync"

  /// Asks for a background refresh while a paired Mac still has audio coming.
  static func schedule() {
    guard MacPairing.load() != nil, !MacOutbox.items().isEmpty || !MacOutbox.marks().isEmpty else { return }
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}
