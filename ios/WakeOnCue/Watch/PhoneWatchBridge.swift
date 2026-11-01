import Foundation
import OSLog
import WatchConnectivity

private let logger = Logger(subsystem: "com.deoooo.WakeOnCue", category: "watch-bridge")

/// iPhone end of the Watch link. Commands arrive as messages, the recording state leaves as
/// application context, and recordings made on the Watch arrive as segment files plus a summary.
final class PhoneWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = PhoneWatchBridge()

  private let lock = NSLock()
  private var requestHandler: (@Sendable (WatchBridgeRequest) async -> WatchBridgeReply)?
  private var inboxHandler: (@Sendable () async -> Void)?
  private var lastPublished: WatchRecordingSnapshot?
  private var pendingSnapshot: WatchRecordingSnapshot?

  private override init() {}

  func install(
    requestHandler: @escaping @Sendable (WatchBridgeRequest) async -> WatchBridgeReply,
    inboxHandler: @escaping @Sendable () async -> Void
  ) {
    lock.withLock {
      self.requestHandler = requestHandler
      self.inboxHandler = inboxHandler
    }
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  func publish(_ snapshot: WatchRecordingSnapshot) {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    let shouldSend: Bool = lock.withLock {
      guard session.activationState == .activated else {
        pendingSnapshot = snapshot
        return false
      }
      if let lastPublished, lastPublished.isEquivalent(to: snapshot) { return false }
      lastPublished = snapshot
      return true
    }
    guard shouldSend, session.isPaired, session.isWatchAppInstalled else { return }
    do {
      try session.updateApplicationContext(
        WatchBridgeCoding.message(WatchBridgeKey.snapshot, snapshot))
    } catch {
      lock.withLock { lastPublished = nil }
      logger.error("Could not publish Watch state: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    let pending = lock.withLock {
      defer { pendingSnapshot = nil }
      return pendingSnapshot
    }
    if let pending { publish(pending) }
    notifyInboxChanged()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // A different Watch was paired; reconnect so the new one gets state too.
    lock.withLock { lastPublished = nil }
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    lock.withLock { lastPublished = nil }
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    let reply = UncheckedReply(send: replyHandler)
    guard
      let request = WatchBridgeCoding.value(
        WatchBridgeRequest.self, key: WatchBridgeKey.request, in: message)
    else {
      reply.send(WatchBridgeReply(failure: .failed("Unsupported request")))
      return
    }
    let handler = lock.withLock { requestHandler }
    Task {
      let response =
        await handler?(request) ?? WatchBridgeReply(failure: .failed("iPhone app is starting"))
      logger.notice(
        "Watch request \(String(describing: request), privacy: .public) -> failure: \(String(describing: response.failure), privacy: .public), phase: \(response.snapshot?.phase.rawValue ?? "-", privacy: .public)"
      )
      reply.send(response)
    }
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    // WatchConnectivity deletes the file when this method returns, so stage it synchronously.
    guard let info = file.metadata else { return }
    do {
      if let segment = WatchBridgeCoding.value(
        WatchSegmentMetadata.self, key: WatchBridgeKey.segment, in: info)
      {
        try WatchSessionInbox.stage(segmentURL: file.fileURL, metadata: segment)
        logger.notice(
          "Watch segment \(segment.index) of \(segment.sessionID.uuidString.prefix(8), privacy: .public) staged")
      } else {
        return
      }
    } catch {
      logger.error("Could not stage a Watch file: \(error.localizedDescription, privacy: .public)")
      return
    }
    notifyInboxChanged()
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard
      let summary = WatchBridgeCoding.value(
        WatchSessionSummary.self, key: WatchBridgeKey.session, in: userInfo)
    else { return }
    do {
      try WatchSessionInbox.stage(summary: summary)
      logger.notice(
        "Watch recording summary \(summary.sessionID.uuidString.prefix(8), privacy: .public): \(summary.segmentCount) segments")
    } catch {
      logger.error("Could not stage a Watch summary: \(error.localizedDescription, privacy: .public)")
      return
    }
    notifyInboxChanged()
  }

  private func notifyInboxChanged() {
    guard let inboxHandler = lock.withLock({ inboxHandler }) else { return }
    Task { await inboxHandler() }
  }
}

/// WatchConnectivity calls reply handlers from any queue; one reply per message is guaranteed
/// by the call sites above.
private struct UncheckedReply: @unchecked Sendable {
  let send: ([String: Any]) -> Void

  func send(_ reply: WatchBridgeReply) {
    send((try? WatchBridgeCoding.message(WatchBridgeKey.reply, reply)) ?? [:])
  }
}
