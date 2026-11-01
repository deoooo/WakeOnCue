import Foundation
import Observation
import WatchKit
import WidgetKit

/// What the "saved" screen is confirming, and where a tag choice has to go.
struct WatchCaptureResult: Identifiable, Equatable {
  enum Destination: Equatable {
    /// A span marked inside the recording that is running on iPhone.
    case phone(WatchMarkResult)
    /// A span marked inside the recording that is running on the Watch.
    case watchRecording(sessionID: UUID, bookmarkID: UUID)
  }

  let id = UUID()
  let destination: Destination
  let savedSeconds: TimeInterval
  var tag: RecordingMarkTag?
}

@MainActor
@Observable
final class WatchModel {
  static let recentDuration: TimeInterval = 120

  private(set) var snapshot = WatchSnapshotStore.load()
  private(set) var isReachable = false
  private(set) var isWorking = false
  private(set) var inputLevel: Float = 0
  /// Start of the recording the Watch itself is making, if any.
  private(set) var watchRecordingStartedAt: Date?
  @ObservationIgnored private var watchRecordingSessionID: UUID?
  var captureResult: WatchCaptureResult?
  var message: String?

  @ObservationIgnored private let session = WatchSessionClient.shared
  @ObservationIgnored private let recorder = WatchAudioRecorder()
  @ObservationIgnored private var meterTask: Task<Void, Never>?
  /// The sheet binding clears `captureResult` before `onDismiss` runs, so keep our own copy.
  @ObservationIgnored private var openCapture: WatchCaptureResult?

  init() {
    session.install(
      snapshotHandler: { [weak self] snapshot in
        Task { @MainActor in self?.apply(snapshot) }
      },
      reachabilityHandler: { [weak self] reachable in
        Task { @MainActor in self?.isReachable = reachable }
      }
    )
    recorder.onStopped = { [weak self] in self?.captureStoppedBySystem() }
    recorder.onSegmentFinished = { [weak self] segment, url in
      self?.segmentFinished(segment, url: url)
    }
    WatchDiagnostics.logBattery("process launched")  // Also turns on battery monitoring so later readings are fresh.
    session.activate()
    WatchSnapshotStore.watchRecordingStartedAt = nil
  }

  var phoneIsRecording: Bool { isReachable && snapshot.isActive }
  var isWatchRecording: Bool { watchRecordingStartedAt != nil }
  var isRecording: Bool { isWatchRecording || phoneIsRecording }

  // MARK: - Actions

  func refresh() async {
    isReachable = session.isReachable
    _ = await perform(.snapshot, quietly: true)
  }

  /// "Save what was just said": marks the last two minutes of whichever recording is running.
  func captureRecent() async {
    guard !isWorking else { return }
    if isWatchRecording {
      markWatchRecording(seconds: Self.recentDuration)
      return
    }
    if phoneIsRecording {
      isWorking = true
      let reply = await perform(.markRecent(seconds: Self.recentDuration), quietly: true)
      isWorking = false
      if let mark = reply?.mark {
        present(WatchCaptureResult(destination: .phone(mark), savedSeconds: mark.savedSeconds))
        return
      }
    }
    message = String(localized: "Start recording first.")
    WKInterfaceDevice.current().play(.failure)
  }

  func bookmark() async {
    if isWatchRecording {
      markWatchRecording(seconds: 0)
      message = String(localized: "Bookmark added")
      WKInterfaceDevice.current().play(.click)
      return
    }
    guard let reply = await perform(.bookmark), reply.mark != nil else { return }
    message = String(localized: "Bookmark added")
    WKInterfaceDevice.current().play(.click)
  }

  func togglePause() async {
    if isWatchRecording {
      stopWatchRecording(reason: "user")
      return
    }
    switch phoneIsRecording ? snapshot.phase : .idle {
    case .recording: _ = await perform(.pause)
    case .paused: _ = await perform(.resume)
    case .idle: await startRecording()
    case .finishing: break
    }
  }

  /// Records on iPhone when it can start; otherwise (unreachable, or iOS refuses because the
  /// app is in the background) the Watch records by itself.
  func startRecording() async {
    guard !isWorking, !isWatchRecording else { return }
    isWorking = true
    defer { isWorking = false }
    var phoneRefused = false
    if isReachable {
      let reply = await perform(.start, quietly: true)
      if let reply, reply.failure == nil, reply.snapshot?.isActive == true { return }
      phoneRefused = true
      WatchDiagnostics.log("iPhone start failed: \(String(describing: reply?.failure))")
    }
    await startWatchRecording()
    if phoneRefused, isWatchRecording {
      message = String(localized: "iPhone can't start recording right now. Recording on Watch instead.")
    }
  }

  func finish() async {
    _ = await perform(.finish)
  }

  func choose(tag: RecordingMarkTag) async {
    guard var result = openCapture else { return }
    result.tag = result.tag == tag ? nil : tag
    openCapture = result
    captureResult = result
    switch result.destination {
    case .phone(let mark):
      _ = await perform(
        .tagBookmark(recordingID: mark.recordingID, bookmarkID: mark.bookmarkID, tag: result.tag),
        quietly: true
      )
    case .watchRecording(let sessionID, let bookmarkID):
      let tag = result.tag
      WatchRecordingStore.update(sessionID) { state in
        guard let index = state.summary.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
          return
        }
        state.summary.bookmarks[index].tag = tag
      }
    }
  }

  /// Called when the saved screen closes. Tags are applied as they are chosen.
  func finishCapture() {
    openCapture = nil
    captureResult = nil
  }

  func handle(url: URL) async {
    guard url == WatchSnapshotStore.captureURL else { return }
    await refresh()
    await captureRecent()
  }

  // MARK: - Watch recording

  private func startWatchRecording() async {
    let sessionID = UUID()
    let startedAt = Date()
    WatchRecordingStore.save(
      WatchRecordingState(
        summary: WatchSessionSummary(
          sessionID: sessionID, startedAt: startedAt, endedAt: startedAt, segmentCount: 0)))
    session.setActiveSession(sessionID)
    do {
      try await recorder.startRecording(
        sessionID: sessionID, directory: WatchRecordingStore.directory(for: sessionID))
    } catch {
      session.setActiveSession(nil)
      try? FileManager.default.removeItem(at: WatchRecordingStore.directory(for: sessionID))
      message = error.localizedDescription
      WKInterfaceDevice.current().play(.failure)
      return
    }
    watchRecordingSessionID = sessionID
    watchRecordingStartedAt = startedAt
    WatchSnapshotStore.watchRecordingStartedAt = startedAt
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording on")
    startMeter()
    WKInterfaceDevice.current().play(.start)
  }

  private func stopWatchRecording(reason: String) {
    guard let sessionID = watchRecordingSessionID else { return }
    let segmentCount = recorder.isRecording ? recorder.stopRecording(reason: reason) : nil
    watchRecordingSessionID = nil
    watchRecordingStartedAt = nil
    WatchSnapshotStore.watchRecordingStartedAt = nil
    session.setActiveSession(nil)
    WatchRecordingStore.update(sessionID) { state in
      if let segmentCount { state.summary.segmentCount = segmentCount }
      state.summary.endedAt = Date()
      state.summary.endReason = reason
      state.isEnded = true
    }
    if let state = WatchRecordingStore.load(sessionID) { session.queue(summary: state.summary) }
    stopMeter()
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording off reason=\(reason)")
    message = String(localized: "Watch recording saved. It syncs to iPhone when nearby.")
    WKInterfaceDevice.current().play(.stop)
  }

  private func segmentFinished(_ segment: WatchSegmentMetadata, url: URL) {
    WatchRecordingStore.update(segment.sessionID) { state in
      state.summary.segmentCount = max(state.summary.segmentCount, segment.index)
    }
    session.transfer(segment: segment, url: url)
  }

  /// `seconds == 0` drops a point bookmark; otherwise the span ending now is marked.
  private func markWatchRecording(seconds: TimeInterval) {
    guard let sessionID = watchRecordingSessionID, let startedAt = watchRecordingStartedAt else {
      return
    }
    let end = Date().timeIntervalSince(startedAt)
    let start = max(0, end - seconds)
    let bookmark = WatchSessionBookmark(
      position: start, duration: seconds > 0 ? end - start : nil)
    WatchRecordingStore.update(sessionID) { $0.summary.bookmarks.append(bookmark) }
    guard seconds > 0 else { return }
    present(
      WatchCaptureResult(
        destination: .watchRecording(sessionID: sessionID, bookmarkID: bookmark.id),
        savedSeconds: end - start))
  }

  private func captureStoppedBySystem() {
    if isWatchRecording { stopWatchRecording(reason: "interruption") }
  }

  // MARK: - Private

  private func present(_ result: WatchCaptureResult) {
    finishCapture()
    message = nil
    openCapture = result
    captureResult = result
    WKInterfaceDevice.current().play(.success)
  }

  private func perform(_ request: WatchBridgeRequest, quietly: Bool = false) async
    -> WatchBridgeReply?
  {
    do {
      let reply = try await session.send(request)
      if let failure = reply.failure, !quietly {
        message = Self.describe(failure)
        WKInterfaceDevice.current().play(.failure)
      }
      return reply
    } catch {
      if !quietly {
        message = error.localizedDescription
        WKInterfaceDevice.current().play(.failure)
      }
      isReachable = session.isReachable
      return nil
    }
  }

  private func apply(_ snapshot: WatchRecordingSnapshot) {
    let changed = !snapshot.isEquivalent(to: self.snapshot) || snapshot.phase != self.snapshot.phase
    self.snapshot = snapshot
    if changed { WidgetCenter.shared.reloadAllTimelines() }
  }

  private func startMeter() {
    meterTask?.cancel()
    meterTask = Task { [weak self] in
      var lastBatteryLog = Date()
      while !Task.isCancelled {
        guard let self else { return }
        self.inputLevel = self.recorder.inputLevel
        if Date().timeIntervalSince(lastBatteryLog) >= 300 {
          lastBatteryLog = Date()
          WatchDiagnostics.logBattery(
            "periodic watchRecording=\(self.isWatchRecording)")
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  private func stopMeter() {
    meterTask?.cancel()
    meterTask = nil
    inputLevel = 0
  }

  private static func describe(_ failure: WatchBridgeFailure) -> String {
    switch failure {
    case .notRecording: String(localized: "iPhone is not recording.")
    case .busy: String(localized: "iPhone is busy. Try again.")
    case .failed(let message): message
    }
  }
}
