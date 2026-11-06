@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

/// Records all day: the microphone always. Restarts itself after device changes and sleep,
/// pauses on request or when the disk is nearly full, and records why it could not record as a
/// gap.
@Observable
final class Recorder {
  enum State: Equatable {
    case off
    case recording
    case paused(until: Date)
    case unavailable(reason: String)
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Recorder")

  private(set) var state: State = .off {
    didSet { if state != oldValue { Self.logger.notice("State: \(String(describing: self.state), privacy: .public)") } }
  }
  private(set) var microphoneName = ""
  /// True when the preferred built-in microphone was unavailable and another one was used.
  private(set) var microphoneFellBack = false
  private(set) var microphoneLevel: Float = 0
  private(set) var diskWarning: String?
  private(set) var writeIssue: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var microphone: MicrophoneCapture?
  @ObservationIgnored private(set) var micPipeline: ChannelPipeline!
  @ObservationIgnored private var segmentIDs: [String: Int64] = [:]
  @ObservationIgnored private var openGapID: Int64?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var restartTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// A pause or resume is in progress; a second toggle in the meantime is ignored.
  @ObservationIgnored private var toggling = false
  /// When the current pause began, for the "still paused" reminder.
  @ObservationIgnored private var pausedSince: Date?
  @ObservationIgnored private var pauseRemindersSent = 0
  /// Receives every converted buffer; the transcriber plugs in here.
  @ObservationIgnored let audioOut = AudioFanout()
  /// Called whenever capture stops, so the transcriber can finalize what it heard.
  @ObservationIgnored var onCaptureStopped: (() -> Void)?

  init(store: Store, preferences: Preferences) {
    self.store = store
    self.preferences = preferences
    let onSegment: @Sendable (SegmentEvent) -> Void = { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    let audioOut = audioOut
    micPipeline = ChannelPipeline(
      channel: .microphone, source: "Mac 麦克风", onSegment: onSegment,
      onAudio: { buffer in audioOut.send(.microphone, buffer) })
    recoverOpenSegments()
    store.closeOpenGaps(at: .now)
    recordDowntime()
    observeWorkspace()
  }

  var isRecording: Bool { state == .recording }

  /// Starts recording unless the user paused it or turned all-day recording off.
  func startIfAllowed() async {
    guard preferences.onboarded, preferences.alwaysRecord else {
      state = .off
      return
    }
    if let until = preferences.pausedUntil, until > .now {
      state = .paused(until: until)
      pausedSince = store.marks(overlapping: DateInterval(start: .now, duration: 1)).first { $0.kind == .paused }?.start ?? .now
      if until == .distantFuture { Self.requestNotificationPermission() }
      startTicker()
      return
    }
    preferences.pausedUntil = nil
    await start()
  }

  private func start() async {
    guard await MicrophoneCapture.requestAccess() else {
      fail(CaptureError.microphoneDenied.localizedDescription)
      return
    }
    if let reason = diskBlocker() {
      fail(reason)
      return
    }
    stopCapture()
    let capture = MicrophoneCapture()
    micPipeline.start()
    do {
      try capture.start(builtIn: preferences.microphone == .builtIn, into: micPipeline) { [weak self] in
        Task { @MainActor in self?.scheduleRestart() }
      }
    } catch {
      micPipeline.stop()
      fail(error.localizedDescription)
      return
    }
    microphone = capture
    microphoneName = capture.deviceName
    microphoneFellBack = capture.fellBack
    if let openGapID {
      store.closeGap(id: openGapID, end: .now)
      self.openGapID = nil
    }
    state = .recording
    preferences.recordingHeartbeat = .now
    preferences.quitCleanly = false
    startTicker()
  }

  func pause(until: Date) {
    store.closeMarks(.paused, at: .now)
    store.addMark(.paused, start: .now, end: until == .distantFuture ? Date(timeIntervalSince1970: 4_102_444_800) : until)
    preferences.pausedUntil = until
    preferences.recordingHeartbeat = nil
    stopCapture()
    state = .paused(until: until)
    pausedSince = .now
    pauseRemindersSent = 0
    if until == .distantFuture { Self.requestNotificationPermission() }
    startTicker()
  }

  func resume() async {
    store.closeMarks(.paused, at: .now)
    preferences.pausedUntil = nil
    pausedSince = nil
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pauseReminderID])
    await start()
  }

  /// ⌃⌥P and the toolbar button. Ignores a second toggle while one is still starting the
  /// microphone, so a double trigger cannot leave recording paused right after resuming.
  func togglePause() async {
    guard !toggling else {
      Self.logger.notice("Ignored a pause toggle while another was in progress")
      return
    }
    toggling = true
    defer { toggling = false }
    if case .recording = state {
      pause(until: .distantFuture)
    } else {
      await resume()
    }
  }

  /// All-day recording was switched off in Settings.
  func turnOff() {
    preferences.recordingHeartbeat = nil
    stopCapture()
    state = .off
  }

  /// The app is quitting. Keeps the heartbeat, so the next launch records the time the app was
  /// not running.
  func quit() {
    if state == .recording {
      preferences.recordingHeartbeat = .now
      preferences.quitCleanly = true
    }
    stopCapture()
    state = .off
  }

  private func stopCapture() {
    if let microphone {
      microphone.stop()
      // The engine may still deliver property callbacks for a moment; keep it alive until then.
      Task {
        try? await Task.sleep(for: .seconds(5))
        _ = microphone
      }
    }
    microphone = nil
    micPipeline.stop()
    microphoneName = ""
    microphoneFellBack = false
    microphoneLevel = 0
    onCaptureStopped?()
  }

  private func fail(_ reason: String) {
    preferences.recordingHeartbeat = nil
    stopCapture()
    state = .unavailable(reason: reason)
    if openGapID == nil { openGapID = store.openGap(start: .now, reason: reason) }
    startTicker()
  }

  /// Device changes stop the engine; give Core Audio a moment, then start over.
  private func scheduleRestart() {
    restartTask?.cancel()
    restartTask = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, state == .recording || isUnavailable else { return }
      await start()
    }
  }

  private var isUnavailable: Bool {
    if case .unavailable = state { return true }
    return false
  }

  // MARK: Periodic work

  private func startTicker() {
    guard ticker == nil else { return }
    ticker = Task { [weak self] in
      var count = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        guard let self else { return }
        count += 1
        self.microphoneLevel = self.micPipeline.level
        if count % 15 == 0 { await self.everyThreeSeconds() }
      }
    }
  }

  private func everyThreeSeconds() async {
    switch state {
    case .recording:
      preferences.recordingHeartbeat = .now
      if let reason = diskBlocker() { fail(reason) }
    case .paused(let until):
      if until <= .now {
        await resume()
      } else if until == .distantFuture {
        remindIfPausedLong()
      }
    case .unavailable:
      // Retry quietly, e.g. after the user turns the microphone permission back on.
      if MicrophoneCapture.isAuthorized, diskBlocker() == nil { await start() }
    case .off:
      break
    }
  }

  /// Pauses below 2 GB free and warns below 10 GB. Never deletes recordings to make room.
  private func diskBlocker() -> String? {
    let values = try? Store.rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
    let gigabyte: Int64 = 1_000_000_000
    diskWarning = free < 10 * gigabyte ? "磁盘剩余不到 10 GB" : nil
    return free < 2 * gigabyte ? "磁盘空间不足（剩余不到 2 GB）" : nil
  }

  // MARK: Segments

  private func handle(_ event: SegmentEvent) {
    switch event {
    case .opened(let channel, let path, let start, let source):
      segmentIDs[path] = store.insertSegment(channel: channel, start: start, path: path, source: source)
      writeIssue = nil
    case .closed(let path, let end, let source):
      if let id = segmentIDs.removeValue(forKey: path) { store.finishSegment(id: id, end: end, source: source) }
    case .failed(let message):
      writeIssue = message
    }
  }

  /// Segments a crash left open get their end time from the audio actually in the file.
  private func recoverOpenSegments() {
    for segment in store.openSegments() {
      let url = Store.audioDirectory.appending(path: segment.path)
      guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
        try? FileManager.default.removeItem(at: url)
        store.removeSegment(id: segment.id)
        continue
      }
      let seconds = Double(file.length) / file.processingFormat.sampleRate
      store.finishSegment(id: segment.id, end: segment.start.addingTimeInterval(seconds), source: segment.source)
    }
  }

  // MARK: Time not recorded

  /// The app was not running since the last heartbeat (quit, crash, power loss, restart).
  private func recordDowntime() {
    defer {
      preferences.recordingHeartbeat = nil
      preferences.quitCleanly = false
    }
    guard let gap = Self.downtime(heartbeat: preferences.recordingHeartbeat, quitCleanly: preferences.quitCleanly, now: .now)
    else { return }
    let id = store.openGap(start: gap.start, reason: gap.reason)
    store.closeGap(id: id, end: gap.end)
    Self.logger.notice("Recorded \(Int(gap.end.timeIntervalSince(gap.start)))s while the app was not running")
  }

  /// Gaps shorter than this are a normal relaunch, not worth showing.
  nonisolated static let downtimeThreshold: TimeInterval = 60

  nonisolated static func downtime(heartbeat: Date?, quitCleanly: Bool, now: Date) -> (start: Date, end: Date, reason: String)? {
    guard let heartbeat, now.timeIntervalSince(heartbeat) >= downtimeThreshold else { return nil }
    return (heartbeat, now, quitCleanly ? "WakeOnCue 没有运行" : "WakeOnCue 意外退出，或 Mac 关机、重启")
  }

  // MARK: Long pause reminder

  nonisolated static let pauseReminderID = "paused-reminder"

  /// Hours after a manual pause began at which to remind: 1, 3, 6, then every 6 hours.
  nonisolated static func pauseReminderDue(pausedFor: TimeInterval, alreadySent: Int) -> Bool {
    let hours: [Double] = [1, 3, 6]
    let next = alreadySent < hours.count ? hours[alreadySent] : 6 + Double(alreadySent - hours.count + 1) * 6
    return pausedFor >= next * 3_600
  }

  /// How many reminders are due after this long a pause.
  nonisolated static func remindersDue(pausedFor: TimeInterval) -> Int {
    var count = 0
    while pauseReminderDue(pausedFor: pausedFor, alreadySent: count) { count += 1 }
    return count
  }

  private func remindIfPausedLong() {
    guard let pausedSince else { return }
    let pausedFor = Date.now.timeIntervalSince(pausedSince)
    guard Self.pauseReminderDue(pausedFor: pausedFor, alreadySent: pauseRemindersSent) else { return }
    // One reminder, even when several are due at once (a pause carried over from before a
    // relaunch); otherwise they would follow each other every few seconds.
    pauseRemindersSent = Self.remindersDue(pausedFor: pausedFor)
    let content = UNMutableNotificationContent()
    content.title = "录音已暂停 \(Int(pausedFor / 3_600)) 小时"
    content.body = "全天录音要手动继续。点菜单栏的 WakeOnCue，或按 ⌃⌥P 继续录音。"
    content.categoryIdentifier = Self.pauseReminderCategory
    let request = UNNotificationRequest(identifier: Self.pauseReminderID, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
    Self.logger.notice("Reminded that recording has been paused for \(Int(pausedFor))s")
  }

  nonisolated static let pauseReminderCategory = "paused"
  nonisolated static let resumeAction = "resume"

  private static func requestNotificationPermission() {
    let center = UNUserNotificationCenter.current()
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: pauseReminderCategory,
        actions: [UNNotificationAction(identifier: resumeAction, title: "继续录音")],
        intentIdentifiers: [])
    ])
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  // MARK: Sleep and wake

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state == .recording else { return }
        self.stopCapture()
        // Closed by `start()` after waking; a launch closes it if the Mac shut down instead.
        if self.openGapID == nil { self.openGapID = self.store.openGap(start: .now, reason: "Mac 休眠或合盖") }
        self.preferences.recordingHeartbeat = nil
      }
    })
    observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state == .recording else { return }
        Task { await self.start() }
      }
    })
  }
}

/// Hands audio from the capture queues to whoever listens, without touching the main actor.
nonisolated final class AudioFanout: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (AudioChannel, TimedBuffer) -> Void)?
  /// A short-lived second listener, e.g. while the user records their voiceprint.
  private var tap: (@Sendable (AudioChannel, TimedBuffer) -> Void)?

  func connect(_ handler: @escaping @Sendable (AudioChannel, TimedBuffer) -> Void) {
    lock.withLock { self.handler = handler }
  }

  func setTap(_ tap: (@Sendable (AudioChannel, TimedBuffer) -> Void)?) {
    lock.withLock { self.tap = tap }
  }

  func send(_ channel: AudioChannel, _ buffer: TimedBuffer) {
    let (handler, tap) = lock.withLock { (self.handler, self.tap) }
    handler?(channel, buffer)
    tap?(channel, buffer)
  }
}
