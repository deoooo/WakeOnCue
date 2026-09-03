import SwiftUI

@main
struct WakeOnCueApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel.bootstrap()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .task {
          model.bind(appDelegate: appDelegate)
          await model.start()
        }
        .onOpenURL { url in
          Task { await model.handle(url: url) }
        }
    }
  }
}
