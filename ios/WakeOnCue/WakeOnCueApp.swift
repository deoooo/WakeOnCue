import SwiftUI

@main
struct WakeOnCueApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel.bootstrap()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .task {
          #if DEBUG && targetEnvironment(simulator)
            do { try await ExperienceFixtures.prepareIfRequested() }
            catch { model.errorMessage = "Experience fixture setup failed: \(error.localizedDescription)" }
          #endif
          model.bind(appDelegate: appDelegate)
          await model.start()
        }
        .onOpenURL { url in
          Task { await model.handle(url: url) }
        }
    }
  }
}
