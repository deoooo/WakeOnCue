@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation
import OSLog

/// Records all day: the microphone always, and the chosen meeting apps whenever they play
/// sound. Restarts itself after device changes and sleep, pauses on request or when the disk
/// is nearly full, and records why it could not record as a gap.
@Observable
final class Recorder {
  enum State: Equatable {
    case off
    case recording
    case paused(until: Date)
    case unavailable(reason: String)
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Recorder")
  /// Keep tapping a meeting app this long after it goes quiet, so pauses in a call stay in one piece.
  private static let meetingHold: TimeInterval = 90

  private(set) var state: State = .off {
    didSet { if state != oldValue { Self.logger.notice("State: \(String(describing: self.state), privacy: .public)") } }
  }
  private(set) var microphoneName = ""
  private(set) var microphoneLevel: Float = 0
  private(set) var meetingLevel: Float = 0
  /// Names of the meeting apps being recorded right now.
  private(set) var activeMeetingApps: [String] = []
  private(set) var meetingAudioIssue: String?
  private(set) var diskWarning: String?
  private(set) var writeIssue: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var microphone: MicrophoneCapture?
  @ObservationIgnored private let meetingCapture = MeetingAudioCapture()
  @ObservationIgnored private(set) var micPipeline: ChannelPipeline!
  @ObservationIgnored private(set) var meetingPipeline: ChannelPipeline!
  @ObservationIgnored private var segmentIDs: [String: Int64] = [:]
  @ObservationIgnored private var lastHeard: [AudioObjectID: (bundleID: String, at: Date)] = [:]
  @ObservationIgnored private var openGapID: Int64?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var restartTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
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
    meetingPipeline = ChannelPipeline(
      channel: .meeting, source: "会议 App", onSegment: onSegment,
      onAudio: { buffer in audioOut.send(.meeting, buffer) })
    recoverOpenSegments()
    store.closeOpenGaps(at: .now)
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
    if let openGapID {
      store.closeGap(id: openGapID, end: .now)
      self.openGapID = nil
    }
    state = .recording
    startTicker()
    refreshMeetingAudio()
  }

  func pause(until: Date) {
    store.closeMarks(.paused, at: .now)
    store.addMark(.paused, start: .now, end: until == .distantFuture ? Date(timeIntervalSince1970: 4_102_444_800) : until)
    preferences.pausedUntil = until
    stopCapture()
    state = .paused(until: until)
    startTicker()
  }

  func resume() async {
    store.closeMarks(.paused, at: .now)
    preferences.pausedUntil = nil
    await start()
  }

  func togglePause() async {
    if case .recording = state {
      pause(until: .distantFuture)
    } else {
      await resume()
    }
  }

  func turnOff() {
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
    meetingCapture.stop()
    meetingPipeline.stop()
    activeMeetingApps = []
    microphoneLevel = 0
    meetingLevel = 0
    onCaptureStopped?()
  }

  private func fail(_ reason: String) {
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
        self.meetingLevel = self.meetingPipeline.level
        if count % 15 == 0 { await self.everyThreeSeconds() }
      }
    }
  }

  private func everyThreeSeconds() async {
    switch state {
    case .recording:
      refreshMeetingAudio()
      if let reason = diskBlocker() { fail(reason) }
    case .paused(let until):
      if until <= .now { await resume() }
    case .unavailable:
      // Retry quietly, e.g. after the user turns the microphone permission back on.
      if MicrophoneCapture.isAuthorized, diskBlocker() == nil { await start() }
    case .off:
      break
    }
  }

  /// Taps the enabled apps that played sound recently, and rebuilds the tap when that set or
  /// the output device changes.
  func refreshMeetingAudio() {
    guard state == .recording else { return }
    let now = Date()
    let enabled = preferences.meetingApps.filter(\.enabled)
    for process in AudioDevices.processes() where process.isPlaying {
      if enabled.contains(where: { $0.matches(process.bundleID) }) {
        lastHeard[process.object] = (process.bundleID, now)
      }
    }
    lastHeard = lastHeard.filter { now.timeIntervalSince($0.value.at) < Self.meetingHold }
    let wanted = lastHeard.keys.sorted()
    let names = Set(lastHeard.values.compactMap { entry in enabled.first { $0.matches(entry.bundleID) }?.name }).sorted()
    let outputChanged = meetingCapture.isRunning && meetingCapture.outputUID != AudioDevices.defaultOutputUID()

    guard wanted != meetingCapture.processes || outputChanged else { return }
    meetingCapture.stop()
    meetingPipeline.stop()
    activeMeetingApps = names
    guard !wanted.isEmpty else { return }
    meetingPipeline.source = names.joined(separator: "、")
    meetingPipeline.start()
    do {
      try meetingCapture.start(processes: wanted, into: meetingPipeline)
      meetingAudioIssue = nil
    } catch {
      meetingPipeline.stop()
      activeMeetingApps = []
      meetingAudioIssue = error.localizedDescription
      Self.logger.error("Meeting audio unavailable: \(error.localizedDescription, privacy: .public)")
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

  // MARK: Sleep and wake

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state == .recording else { return }
        self.stopCapture()
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
