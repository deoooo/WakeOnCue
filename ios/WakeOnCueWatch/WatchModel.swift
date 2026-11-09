import Foundation
import Observation
import WatchKit
import WidgetKit

/// The Watch records by itself, all day. Each minute of audio goes to the iPhone as it is written;
/// the screen shows what was recorded and how much of it has reached the iPhone.
@MainActor
@Observable
final class WatchModel {
  private(set) var isReachable = false
  private(set) var isWorking = false
  private(set) var inputLevel: Float = 0
  /// Start of the recording the Watch is making, if any.
  private(set) var watchRecordingStartedAt: Date?
  /// Recordings still known to the Watch, newest first.
  private(set) var recordings: [WatchRecordingStatus] = []
  var message: String?

  @ObservationIgnored private var watchRecordingSessionID: UUID?
  @ObservationIgnored private let session = WatchSessionClient.shared
  @ObservationIgnored private let recorder = WatchAudioRecorder()
  @ObservationIgnored private var meterTask: Task<Void, Never>?

  init() {
    session.install(reachabilityHandler: { [weak self] reachable in
      Task { @MainActor in self?.isReachable = reachable }
    })
    recorder.onStopped = { [weak self] reason in self?.captureStoppedBySystem(reason) }
    recorder.onSegmentFinished = { [weak self] segment, url in
      self?.segmentFinished(segment, url: url)
    }
    WatchDiagnostics.logBattery("process launched")  // Also turns on battery monitoring so later readings are fresh.
    session.activate()
    WatchSnapshotStore.watchRecordingStartedAt = nil
    WatchRecordingStore.pruneHistory()
    reloadRecordings()
  }

  var isWatchRecording: Bool { watchRecordingStartedAt != nil }

  /// Segments recorded but not yet confirmed by the iPhone, across all recordings.
  var pendingSegments: Int { recordings.reduce(0) { $0 + $1.pendingSegments } }
  /// Ended recordings whose summary has not reached the iPhone yet.
  var pendingSummaries: Int {
    recordings.filter { $0.isEnded && !$0.state.isSummaryDelivered }.count
  }

  /// Today's recorded time on the Watch, counting only the part after midnight.
  func todayDuration(at now: Date) -> TimeInterval {
    let midnight = Calendar.current.startOfDay(for: now)
    return recordings.reduce(0) { total, recording in
      let end = recording.startedAt.addingTimeInterval(recording.duration(at: now))
      return total + max(0, end.timeIntervalSince(max(recording.startedAt, midnight)))
    }
  }

  // MARK: - Actions

  func refresh() {
    isReachable = session.isReachable
    reloadRecordings()
  }

  func toggleRecording() async {
    if isWatchRecording {
      stopWatchRecording(reason: "user")
    } else {
      await startWatchRecording()
    }
  }

  // MARK: - Watch recording

  private func startWatchRecording() async {
    guard !isWorking, !isWatchRecording else { return }
    isWorking = true
    defer { isWorking = false }
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
    message = nil
    watchRecordingSessionID = sessionID
    watchRecordingStartedAt = startedAt
    WatchSnapshotStore.watchRecordingStartedAt = startedAt
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording on")
    startMeter()
    reloadRecordings()
    WKInterfaceDevice.current().play(.start)
  }

  private func stopWatchRecording(reason: String) {
    guard let sessionID = watchRecordingSessionID else { return }
    let writeFailed = reason == WatchCaptureStopReason.writeFailure.rawValue
    // Before capture stops: without the audio session a background app may not get to play it.
    if writeFailed { WKInterfaceDevice.current().play(.failure) }
    let segmentCount = recorder.isRecording ? recorder.stopRecording(reason: reason) : nil
    watchRecordingSessionID = nil
    watchRecordingStartedAt = nil
    WatchSnapshotStore.watchRecordingStartedAt = nil
    session.setActiveSession(nil)
    let state = WatchRecordingStore.update(sessionID) { state in
      if let segmentCount { state.summary.segmentCount = segmentCount }
      state.summary.endedAt = Date()
      state.summary.endReason = reason
      state.isEnded = true
    }
    if let state { session.queue(summary: state.summary) }
    stopMeter()
    reloadRecordings()
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording off reason=\(reason)")
    if writeFailed {
      message = (state?.summary.segmentCount ?? 0) > 0
        ? String(localized: "The Watch couldn't keep saving audio, so recording stopped. Saved audio syncs to iPhone.")
        : String(localized: "The Watch couldn't save audio, so recording stopped. Nothing was saved.")
    } else if reason == WatchCaptureStopReason.interruption.rawValue {
      message = String(localized: "Recording stopped by a call or Siri. Tap Record to continue.")
    } else {
      message = nil
      WKInterfaceDevice.current().play(.stop)
    }
  }

  private func segmentFinished(_ segment: WatchSegmentMetadata, url: URL) {
    WatchRecordingStore.update(segment.sessionID) { state in
      state.summary.segmentCount = max(state.summary.segmentCount, segment.index)
    }
    session.transfer(segment: segment, url: url)
    reloadRecordings()
  }

  private func captureStoppedBySystem(_ reason: WatchCaptureStopReason) {
    if isWatchRecording { stopWatchRecording(reason: reason.rawValue) }
  }

  // MARK: - Private

  private func reloadRecordings() {
    let latest = WatchRecordingStore.statuses()
    if latest != recordings { recordings = latest }
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
}
