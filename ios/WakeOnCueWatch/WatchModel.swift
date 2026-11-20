import CoreLocation
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
  private(set) var isInterrupted = false
  private(set) var watchRecordingSessionID: UUID?
  private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
  /// Recordings still known to the Watch, newest first.
  private(set) var recordings: [WatchRecordingStatus] = []
  var message: String?

  @ObservationIgnored private let session = WatchSessionClient.shared
  @ObservationIgnored private let recorder = WatchAudioRecorder()
  @ObservationIgnored private let recoveryLocation = WatchRecoveryLocation()
  @ObservationIgnored private var meterTask: Task<Void, Never>?
  @ObservationIgnored private var resumeTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundRetryTask: Task<Void, Never>?
  @ObservationIgnored private var isActive = false

  init() {
    session.install(reachabilityHandler: { [weak self] reachable in
      Task { @MainActor in self?.isReachable = reachable }
    })
    recorder.onStopped = { [weak self] reason in self?.captureStoppedBySystem(reason) }
    recorder.onInterruptionBegan = { [weak self] in self?.captureInterrupted() }
    recorder.onInterruptionEnded = { [weak self] in self?.scheduleResume() }
    recorder.onSegmentFinished = { [weak self] segment, url in
      self?.segmentFinished(segment, url: url)
    }
    locationAuthorization = recoveryLocation.authorization
    recoveryLocation.onAuthorizationChanged = { [weak self] status in
      self?.locationAuthorization = status
      self?.updateRecoveryLocation()
    }
    WatchDiagnostics.logBattery("process launched")  // Also turns on battery monitoring so later readings are fresh.
    session.activate()
    WatchSnapshotStore.watchRecordingStartedAt = nil
    WatchRecordingStore.pruneHistory()
    reloadRecordings()
  }

  var isWatchRecording: Bool { watchRecordingSessionID != nil }
  var recordedDuration: TimeInterval { recorder.recordedDuration }

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
      let duration = recording.id == watchRecordingSessionID
        ? recordedDuration : recording.duration(at: now)
      let spanToday = recording.end(at: now).timeIntervalSince(max(recording.startedAt, midnight))
      return total + min(duration, max(0, spanToday))
    }
  }

  // MARK: - Actions

  func refresh() {
    isReachable = session.isReachable
    reloadRecordings()
  }

  func sceneActivityChanged(isActive: Bool) {
    self.isActive = isActive
    updateRecoveryLocation()
    if isActive {
      // Older watchOS versions may omit the interruption-ended notification.
      scheduleResume()
    } else if !canResumeInBackground {
      cancelResume()
    }
  }

  func resumeWatchRecording() {
    cancelResume()
    _ = attemptResume(allowBackground: false)
  }

  func autoResumePreferenceChanged() {
    cancelResume()
    updateRecoveryLocation()
    scheduleResume()
  }

  func backgroundResumePreferenceChanged(enabled: Bool) {
    if enabled, locationAuthorization == .notDetermined {
      recoveryLocation.requestAuthorization()
    }
    autoResumePreferenceChanged()
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
          sessionID: sessionID, startedAt: startedAt, endedAt: startedAt, segmentCount: 0),
        capturedDuration: 0))
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
    updateRecoveryLocation()
    WatchSnapshotStore.watchRecordingStartedAt = startedAt
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording on")
    startMeter()
    reloadRecordings()
    WKInterfaceDevice.current().play(.start)
  }

  private func stopWatchRecording(reason: String) {
    guard let sessionID = watchRecordingSessionID else { return }
    cancelResume()
    let writeFailed = reason == WatchCaptureStopReason.writeFailure.rawValue
    // Before capture stops: without the audio session a background app may not get to play it.
    if writeFailed { WKInterfaceDevice.current().play(.failure) }
    let segmentCount = recorder.isRecording ? recorder.stopRecording(reason: reason) : nil
    watchRecordingSessionID = nil
    isInterrupted = false
    updateRecoveryLocation()
    WatchSnapshotStore.watchRecordingStartedAt = nil
    let state = WatchRecordingStore.update(sessionID) { state in
      if let segmentCount { state.summary.segmentCount = segmentCount }
      state.summary.endedAt = Date()
      state.summary.endReason = reason
      state.isEnded = true
    }
    session.setActiveSession(nil)
    if let state { session.queue(summary: state.summary) }
    stopMeter()
    reloadRecordings()
    WidgetCenter.shared.reloadAllTimelines()
    WatchDiagnostics.logBattery("watch recording off reason=\(reason)")
    if writeFailed {
      message = (state?.summary.segmentCount ?? 0) > 0
        ? String(localized: "The Watch couldn't keep saving audio, so recording stopped. Saved audio syncs to iPhone.")
        : String(localized: "The Watch couldn't save audio, so recording stopped. Nothing was saved.")
    } else {
      message = nil
      WKInterfaceDevice.current().play(.stop)
    }
  }

  private func segmentFinished(_ segment: WatchSegmentMetadata, url: URL) {
    WatchRecordingStore.update(segment.sessionID) { state in
      state.summary.segmentCount = max(state.summary.segmentCount, segment.index)
      state.capturedDuration = (state.capturedDuration ?? 0) + segment.duration
      if !state.isEnded {
        state.summary.endedAt = max(state.summary.endedAt, Date())
      }
    }
    session.transfer(segment: segment, url: url)
    reloadRecordings()
  }

  private func captureStoppedBySystem(_ reason: WatchCaptureStopReason) {
    if isWatchRecording { stopWatchRecording(reason: reason.rawValue) }
  }

  private func captureInterrupted() {
    guard isWatchRecording else { return }
    isInterrupted = true
    WatchSnapshotStore.watchRecordingStartedAt = nil
    WidgetCenter.shared.reloadAllTimelines()
    stopMeter()
    startBackgroundRetries()
  }

  private var canResumeInBackground: Bool {
    WatchRecordingPreferences.backgroundResume && recoveryLocation.isRunning
  }

  private func updateRecoveryLocation() {
    guard isWatchRecording, WatchRecordingPreferences.autoResume,
      WatchRecordingPreferences.backgroundResume, recoveryLocation.isAuthorized
    else {
      recoveryLocation.stop()
      stopBackgroundRetries()
      if !isActive { cancelResume() }
      return
    }
    // Start the location session before an interruption can send the app to the background.
    if isActive { recoveryLocation.start() }
    if isInterrupted { startBackgroundRetries() }
  }

  private func scheduleResume() {
    guard WatchRecordingPreferences.autoResume, isActive || canResumeInBackground,
      isInterrupted, resumeTask == nil
    else {
      return
    }
    resumeTask = Task { [weak self] in
      defer {
        if !Task.isCancelled { self?.resumeTask = nil }
      }
      // The system can signal before the microphone route is ready.
      for delay: Duration in [.zero, .milliseconds(500), .seconds(2)] {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self, WatchRecordingPreferences.autoResume else { return }
        if self.attemptResume(allowBackground: true) { return }
      }
    }
  }

  private func cancelResume() {
    resumeTask?.cancel()
    resumeTask = nil
  }

  /// Returns false only when another attempt could be useful.
  private func attemptResume(allowBackground: Bool) -> Bool {
    guard isActive || (allowBackground && canResumeInBackground),
      isInterrupted, isWatchRecording
    else { return true }
    do {
      try recorder.resumeRecording()
    } catch {
      WatchDiagnostics.log("recording resume failed: \(error.localizedDescription)")
      if isInterrupted {
        message = String(localized: "Microphone unavailable. Tap Resume to try again.")
      }
      return !isInterrupted
    }
    isInterrupted = false
    stopBackgroundRetries()
    message = nil
    WatchSnapshotStore.watchRecordingStartedAt = Date().addingTimeInterval(-recordedDuration)
    WidgetCenter.shared.reloadAllTimelines()
    startMeter()
    return true
  }

  private func startBackgroundRetries() {
    guard canResumeInBackground, backgroundRetryTask == nil else { return }
    backgroundRetryTask = Task { [weak self] in
      // A system interruption can end without a matching notification.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self, self.isInterrupted, self.canResumeInBackground else {
          return
        }
        self.scheduleResume()
      }
    }
  }

  private func stopBackgroundRetries() {
    backgroundRetryTask?.cancel()
    backgroundRetryTask = nil
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

enum WatchRecordingPreferences {
  static let autoResumeKey = "watch.recording.auto-resume"
  static let backgroundResumeKey = "watch.recording.background-resume"

  static var autoResume: Bool {
    UserDefaults.standard.object(forKey: autoResumeKey) as? Bool ?? true
  }

  static var backgroundResume: Bool {
    UserDefaults.standard.bool(forKey: backgroundResumeKey)
  }
}

/// Keeps an opted-in recording eligible for background execution during an audio interruption.
@MainActor
private final class WatchRecoveryLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private(set) var isRunning = false
  var onAuthorizationChanged: ((CLAuthorizationStatus) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
  }

  var authorization: CLAuthorizationStatus { manager.authorizationStatus }
  var isAuthorized: Bool {
    authorization == .authorizedWhenInUse || authorization == .authorizedAlways
  }

  func requestAuthorization() { manager.requestWhenInUseAuthorization() }

  func start() {
    guard isAuthorized, !isRunning else { return }
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
    isRunning = true
  }

  func stop() {
    guard isRunning else { return }
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    isRunning = false
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    onAuthorizationChanged?(manager.authorizationStatus)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    WatchDiagnostics.log("background recording location unavailable: \(error.localizedDescription)")
  }
}
