import Foundation
import OSLog
import WatchConnectivity

private let logger = Logger(subsystem: "com.deoooo.WakeOnCue.watchkitapp", category: "bridge")

enum WatchSessionError: LocalizedError {
  case unreachable
  case invalidReply
  case timedOut

  var errorDescription: String? {
    switch self {
    case .unreachable: String(localized: "iPhone is not reachable.")
    case .invalidReply: String(localized: "iPhone sent an unexpected reply.")
    case .timedOut: String(localized: "iPhone did not answer. Try again.")
    }
  }
}

/// Watch end of the iPhone link. State arrives as application context; commands go out as
/// messages with replies; recording segments leave as queued file transfers that survive disconnects.
final class WatchSessionClient: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = WatchSessionClient()

  private let lock = NSLock()
  private var snapshotHandler: (@Sendable (WatchRecordingSnapshot) -> Void)?
  private var reachabilityHandler: (@Sendable (Bool) -> Void)?
  /// The recording this process is writing right now; never treated as interrupted.
  private var activeSessionID: UUID?

  func setActiveSession(_ sessionID: UUID?) {
    lock.withLock { activeSessionID = sessionID }
  }

  private override init() {}

  func install(
    snapshotHandler: @escaping @Sendable (WatchRecordingSnapshot) -> Void,
    reachabilityHandler: @escaping @Sendable (Bool) -> Void
  ) {
    lock.withLock {
      self.snapshotHandler = snapshotHandler
      self.reachabilityHandler = reachabilityHandler
    }
  }

  func activate() {
    let session = WCSession.default
    guard session.delegate !== self || session.activationState != .activated else { return }
    session.delegate = self
    session.activate()
  }

  var isReachable: Bool { WCSession.default.isReachable }

  func send(
    _ request: WatchBridgeRequest,
    timeout: Duration = .seconds(15)
  ) async throws -> WatchBridgeReply {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      throw WatchSessionError.unreachable
    }
    let message = try WatchBridgeCoding.message(WatchBridgeKey.request, request)
    // WatchConnectivity may never call either handler if the iPhone app stalls, so whichever
    // of reply, error, or timeout comes first resumes the caller exactly once.
    let pending = PendingReply()
    let response: Data = try await withCheckedThrowingContinuation { continuation in
      pending.install(continuation)
      session.sendMessage(
        message,
        replyHandler: { reply in
          guard let data = reply[WatchBridgeKey.reply] as? Data else {
            pending.resume(throwing: WatchSessionError.invalidReply)
            return
          }
          pending.resume(returning: data)
        },
        errorHandler: { error in pending.resume(throwing: error) }
      )
      Task {
        try? await Task.sleep(for: timeout)
        pending.resume(throwing: WatchSessionError.timedOut)
      }
    }
    let reply = try WatchBridgeCoding.decode(WatchBridgeReply.self, from: response)
    if let snapshot = reply.snapshot { deliver(snapshot) }
    return reply
  }

  func transfer(segment: WatchSegmentMetadata, url: URL) {
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    let alreadyQueued = session.outstandingFileTransfers.contains {
      $0.file.fileURL.standardizedFileURL == url.standardizedFileURL
    }
    guard !alreadyQueued,
      let metadata = try? WatchBridgeCoding.message(WatchBridgeKey.segment, segment)
    else { return }
    session.transferFile(url, metadata: metadata)
  }

  /// Queues the end-of-recording summary. `transferUserInfo` survives relaunches and is retried
  /// by the system until the iPhone receives it.
  func queue(summary: WatchSessionSummary) {
    let session = WCSession.default
    guard session.activationState == .activated,
      let info = try? WatchBridgeCoding.message(WatchBridgeKey.session, summary)
    else { return }
    let alreadyQueued = session.outstandingUserInfoTransfers.contains {
      WatchBridgeCoding.value(WatchSessionSummary.self, key: WatchBridgeKey.session, in: $0.userInfo)?
        .sessionID == summary.sessionID
    }
    if !alreadyQueued { session.transferUserInfo(info) }
    WatchRecordingStore.update(summary.sessionID) { $0.isSummaryQueued = true }
  }

  /// Re-sends everything a previous run left undelivered.
  func resendPendingRecordings() {
    for state in WatchRecordingStore.allStates() {
      for (segment, url) in WatchRecordingStore.pendingSegments(of: state) {
        transfer(segment: segment, url: url)
      }
      if state.isEnded, !state.isSummaryDelivered { queue(summary: state.summary) }
    }
  }

  /// Keeps a background refresh task alive until queued context has been delivered.
  func waitForPendingContent(timeout: TimeInterval = 5) async {
    activate()
    let deadline = Date().addingTimeInterval(timeout)
    while WCSession.default.hasContentPending, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    if let snapshot = WatchBridgeCoding.value(
      WatchRecordingSnapshot.self,
      key: WatchBridgeKey.snapshot,
      in: session.receivedApplicationContext
    ) {
      deliver(snapshot)
    }
    lock.withLock { reachabilityHandler }?(session.isReachable)
    _ = WatchRecordingStore.recoverInterrupted(excluding: lock.withLock { activeSessionID })
    resendPendingRecordings()
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    guard
      let snapshot = WatchBridgeCoding.value(
        WatchRecordingSnapshot.self, key: WatchBridgeKey.snapshot, in: context)
    else { return }
    deliver(snapshot)
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    lock.withLock { reachabilityHandler }?(session.isReachable)
  }

  func session(
    _ session: WCSession,
    didFinish fileTransfer: WCSessionFileTransfer,
    error: Error?
  ) {
    if let error {
      logger.error("File transfer failed: \(String(describing: error), privacy: .public)")
      WatchDiagnostics.log("file transfer failed: \(error.localizedDescription)")
      return
    }
    let url = fileTransfer.file.fileURL
    WatchDiagnostics.log(
      "segment delivered \(url.deletingLastPathComponent().lastPathComponent.prefix(8))/\(url.lastPathComponent)")
    WatchRecordingStore.segmentDelivered(at: url)
  }

  func session(
    _ session: WCSession,
    didFinish userInfoTransfer: WCSessionUserInfoTransfer,
    error: Error?
  ) {
    guard
      let summary = WatchBridgeCoding.value(
        WatchSessionSummary.self, key: WatchBridgeKey.session, in: userInfoTransfer.userInfo)
    else { return }
    if let error {
      WatchDiagnostics.log("summary transfer failed: \(error.localizedDescription)")
      return
    }
    WatchDiagnostics.log("summary delivered session=\(summary.sessionID.uuidString.prefix(8))")
    WatchRecordingStore.summaryDelivered(summary.sessionID)
  }

  private func deliver(_ snapshot: WatchRecordingSnapshot) {
    let stored = WatchSnapshotStore.load()
    // Replies and application context can arrive out of order; keep the newest.
    guard snapshot.capturedAt >= stored.capturedAt else { return }
    WatchSnapshotStore.save(snapshot)
    lock.withLock { snapshotHandler }?(snapshot)
  }
}

private final class PendingReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?

  func install(_ continuation: CheckedContinuation<Data, Error>) {
    lock.withLock { self.continuation = continuation }
  }

  func resume(returning data: Data) {
    take()?.resume(returning: data)
  }

  func resume(throwing error: Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Data, Error>? {
    lock.withLock {
      defer { continuation = nil }
      return continuation
    }
  }
}
