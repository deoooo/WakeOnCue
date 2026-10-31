import Foundation
import UserNotifications

/// The app's single `UNUserNotificationCenter` delegate. Features register their notification
/// category with a handler, and taps on that category's notifications are routed to it.
@MainActor
final class NotificationRouter: NSObject {
  static let shared = NotificationRouter()

  struct Response: Sendable {
    var categoryIdentifier: String
    var actionIdentifier: String
    var userInfo: [String: String]

    var isDefaultAction: Bool { actionIdentifier == UNNotificationDefaultActionIdentifier }
  }

  private var categories: [String: UNNotificationCategory] = [:]
  private var handlers: [String: @MainActor (Response) async -> Void] = [:]

  private override init() {
    super.init()
    UNUserNotificationCenter.current().delegate = self
  }

  func register(
    _ category: UNNotificationCategory,
    handler: @escaping @MainActor (Response) async -> Void
  ) {
    categories[category.identifier] = category
    handlers[category.identifier] = handler
    UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
  }

  fileprivate func route(_ response: Response) async {
    await handlers[response.categoryIdentifier]?(response)
  }
}

extension NotificationRouter: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let content = response.notification.request.content
    var userInfo: [String: String] = [:]
    for case let (key as String, value as String) in content.userInfo {
      userInfo[key] = value
    }
    await route(
      Response(
        categoryIdentifier: content.categoryIdentifier,
        actionIdentifier: response.actionIdentifier,
        userInfo: userInfo
      ))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
