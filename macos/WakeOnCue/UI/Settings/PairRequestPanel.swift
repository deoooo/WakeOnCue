import AppKit
import SwiftUI
import UserNotifications

/// The floating window with the pairing code: it appears when a phone asks for one, above every
/// window and also while WakeOnCue is in the background, so nobody has to keep Settings open.
final class PairRequestPanel {
  private let sync: SyncServer
  private var panel: NSPanel?
  private static let notificationID = "pair-request"

  init(sync: SyncServer) {
    self.sync = sync
  }

  func update(_ request: SyncServer.PairRequest?) {
    guard let request else {
      panel?.orderOut(nil)
      panel = nil
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
      return
    }
    let view = PairRequestView(request: request) { [weak sync] in sync?.rejectPairRequest() }
    if let panel, let hosting = panel.contentView as? NSHostingView<PairRequestView> {
      hosting.rootView = view
      panel.setContentSize(hosting.fittingSize)
      return
    }
    let hosting = NSHostingView(rootView: view)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = hosting
    panel.center()
    panel.orderFrontRegardless()
    self.panel = panel
    if request.state == .waiting && !NSApp.isActive {
      Self.notify(id: Self.notificationID, title: "「\(request.deviceName)」想连接这台 Mac", body: "配对码 \(Self.spaced(request.code))")
    }
  }

  /// A phone paired through the QR code: there is no code window to say so.
  static func notifyPaired(_ device: PairedDevice) {
    notify(id: "paired-\(device.id)", title: "「\(device.name)」已配对", body: "它的手表和 iPhone 录音会自动转到这台 Mac。")
  }

  private static func notify(id: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
  }

  static func spaced(_ code: String) -> String {
    code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
  }
}

struct PairRequestView: View {
  let request: SyncServer.PairRequest
  let reject: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "iphone")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      switch request.state {
      case .waiting:
        Text("「\(request.deviceName)」想连接这台 Mac").font(.headline)
        Text("在 iPhone 上输入：").font(.callout).foregroundStyle(.secondary)
        Text(PairRequestPanel.spaced(request.code))
          .font(.system(size: 44, weight: .semibold, design: .monospaced))
          .textSelection(.enabled)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let left = max(0, Int(request.expires.timeIntervalSince(context.date)))
          Text("\(left / 60):\(String(format: "%02d", left % 60)) 内有效")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("拒绝", action: reject)
          .padding(.top, 8)
      case .paired:
        Text("已连接「\(request.deviceName)」").font(.headline)
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(.green)
          .padding(.top, 4)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 24)
    .frame(width: 360)
  }
}
