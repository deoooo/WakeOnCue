import Foundation
import OSLog
import WatchConnectivity

private let logger = Logger(subsystem: "com.deoooo.WakeOnCue.watchkitapp", category: "bridge")

/// Watch end of the iPhone link. Recording segments leave as queued file transfers and the
/// end-of-recording summary as user info; both survive disconnects and relaunches.
final class WatchSessionClient: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = WatchSessionClient()

  private let lock = NSLock()
  private var reachabilityHandler: (@Sendable (Bool) -> Void)?
  /// The recording this process is writing right now; never treated as interrupted.
  private var activeSessionID: UUID?

  func setActiveSession(_ sessionID: UUID?) {
    lock.withLock { activeSessionID = sessionID }
  }

  private override init() {}

  func install(reachabilityHandler: @escaping @Sendable (Bool) -> Void) {
    lock.withLock { self.reachabilityHandler = reachabilityHandler }
  }

  func activate() {
    let session = WCSession.default
    guard session.delegate !== self || session.activationState != .activated else { return }
    session.delegate = self
    session.activate()
  }

  var isReachable: Bool { WCSession.default.isReachable }

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
    lock.withLock { reachabilityHandler }?(session.isReachable)
    _ = WatchRecordingStore.recoverInterrupted(excluding: lock.withLock { activeSessionID })
    resendPendingRecordings()
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
}
