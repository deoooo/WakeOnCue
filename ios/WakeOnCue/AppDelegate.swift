import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  var backgroundUploadHandler: ((@escaping @Sendable () -> Void) -> Void)? {
    didSet {
      guard let pendingBackgroundCompletion, let backgroundUploadHandler else { return }
      self.pendingBackgroundCompletion = nil
      backgroundUploadHandler(pendingBackgroundCompletion)
    }
  }
  private var pendingBackgroundCompletion: (@Sendable () -> Void)?

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    guard identifier == BackgroundUploadCoordinator.sessionIdentifier else {
      completionHandler()
      return
    }
    if let backgroundUploadHandler {
      backgroundUploadHandler(completionHandler)
    } else {
      pendingBackgroundCompletion = completionHandler
    }
  }
}
