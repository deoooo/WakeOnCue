import AVFoundation
import Foundation

enum WatchAudioError: LocalizedError {
  case microphoneDenied
  case invalidInputFormat
  case converterUnavailable

  var errorDescription: String? {
    switch self {
    case .microphoneDenied: String(localized: "Allow microphone access for WakeOnCue in Watch settings.")
    case .invalidInputFormat: String(localized: "The Watch microphone is unavailable.")
    case .converterUnavailable: String(localized: "The Watch cannot prepare audio.")
    }
  }
}

private final class OneShotInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func provide(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      status.pointee = .noDataNow
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}

/// Why capture ended without the user asking. `rawValue` becomes the summary's `endReason`.
enum WatchCaptureStopReason: String, Sendable {
  /// Segments can no longer be opened or written (for example the Watch is out of storage).
  case writeFailure = "write_failure"
}

/// The Watch microphone pipeline. Audio is written as fixed-length AAC segments so a long
/// recording reaches the iPhone piece by piece and a crash loses at most the open segment.
final class WatchAudioRecorder: @unchecked Sendable {
  static let sampleRate = SegmentWriter.sampleRate
  static let segmentDuration = SegmentWriter.segmentDuration

  @MainActor private var engine: AVAudioEngine?
  private let lock = NSLock()
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: WatchAudioRecorder.sampleRate,
    channels: 1,
    interleaved: true
  )!
  private var converter: AVAudioConverter?
  private var removeInterruptionObservers: (() -> Void)?
  private var level: Float = 0
  private var lastHeartbeat = Date.distantPast
  private var recording: SegmentWriter?
  private var isEndingAfterWriteFailure = false

  /// Called on the main actor when capture has to end, while the recording is still open, so the
  /// handler's `stopRecording` returns a segment count that includes the last segment.
  @MainActor var onStopped: (@MainActor @Sendable (WatchCaptureStopReason) -> Void)?
  @MainActor var onInterruptionBegan: (@MainActor @Sendable () -> Void)?
  @MainActor var onInterruptionEnded: (@MainActor @Sendable () -> Void)?
  /// Called on the main actor each time a recording segment is complete on disk.
  var onSegmentFinished: (@MainActor @Sendable (WatchSegmentMetadata, URL) -> Void)?

  deinit {
    removeInterruptionObservers?()
  }

  /// A smoothed 0...1 input level for the on-screen meter.
  var inputLevel: Float { lock.withLock { level } }

  var isRecording: Bool { lock.withLock { recording != nil } }
  var recordedDuration: TimeInterval { lock.withLock { recording?.recordedDuration ?? 0 } }

  /// Starts writing segments into `directory`. Must be called from a foreground user action:
  /// watchOS lets capture continue in the background but not start there.
  @MainActor
  func startRecording(sessionID: UUID, directory: URL) async throws {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw WatchAudioError.microphoneDenied
    }
    observeInterruptions()
    try startEngine()
    do {
      try lock.withLock {
        isEndingAfterWriteFailure = false
        var writer = SegmentWriter(
          sessionID: sessionID, directory: directory, log: { WatchDiagnostics.log($0) })
        try writer.openNext(format: outputFormat)
        recording = writer
      }
    } catch {
      stopEngine()
      throw error
    }
    WatchDiagnostics.log("recording started session=\(sessionID.uuidString.prefix(8))")
  }

  /// Restarts microphone capture into the next segment of the same recording.
  @MainActor
  func resumeRecording() throws {
    guard engine == nil, isRecording else { return }
    try startEngine()
    do {
      try lock.withLock { try recording?.openNext(format: outputFormat) }
    } catch {
      end(because: .writeFailure)
      throw error
    }
    WatchDiagnostics.log("recording resumed")
  }

  /// Closes the open segment and returns how many segments the recording has.
  @MainActor
  @discardableResult
  func stopRecording(reason: String = "user") -> Int {
    let (finished, count) = lock.withLock { () -> ((WatchSegmentMetadata, URL)?, Int) in
      guard var writer = recording else { return (nil, 0) }
      let finished = writer.close()
      recording = nil
      return (finished, writer.completedCount)
    }
    if let finished { onSegmentFinished?(finished.0, finished.1) }
    WatchDiagnostics.log("recording stopped reason=\(reason) segments=\(count)")
    stopEngine()
    return count
  }

  // MARK: - Engine

  @MainActor
  private func startEngine() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)
    do {
      try startInput()
    } catch {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw error
    }
  }

  @MainActor
  private func startInput() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw WatchAudioError.invalidInputFormat
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw WatchAudioError.converterUnavailable
    }
    lock.withLock {
      self.converter = converter
      level = 0
    }
    installTap(on: input, format: inputFormat)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      lock.withLock { self.converter = nil }
      throw error
    }
    self.engine = engine
    WatchDiagnostics.log("engine started input=\(inputFormat.sampleRate)Hz")
  }

  // The tap runs on an audio thread, independently of main-actor engine control.
  private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
    input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] pcm, _ in
      self?.process(pcm)
    }
  }

  @MainActor
  private func stopEngine(deactivateSession: Bool = true) {
    guard let engine else { return }
    self.engine = nil
    lock.withLock {
      converter = nil
      level = 0
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func process(_ input: AVAudioPCMBuffer) {
    guard let converter = lock.withLock({ converter }) else { return }
    let ratio = Self.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return
    }
    let source = OneShotInput(buffer: input)
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in source.provide(status: status) }
    guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else {
      return
    }
    let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
    var peak: Int16 = 0
    for sample in samples where sample.magnitude > peak.magnitude { peak = sample }
    let instant = Float(peak.magnitude) / Float(Int16.max)
    let (heartbeat, finished) = lock.withLock { () -> (String?, (WatchSegmentMetadata, URL)?) in
      guard self.converter === converter else { return (nil, nil) }
      level = max(instant, level * 0.8)
      var finished: (WatchSegmentMetadata, URL)?
      if var writer = recording {
        finished = writer.write(output, format: outputFormat)
        recording = writer
      }
      guard Date().timeIntervalSince(lastHeartbeat) >= 15 else { return (nil, finished) }
      lastHeartbeat = Date()
      let recorded = recording.map { "recording=\(Int($0.recordedDuration))s" } ?? "idle"
      return (recorded, finished)
    }
    if let finished { deliver(finished) }
    if let heartbeat {
      WatchDiagnostics.log("audio heartbeat \(heartbeat) peak=\(peak.magnitude)")
    }
    endIfWritingFailed()
  }

  /// Runs on the audio thread, so it hops to the main actor once, and only ends the recording
  /// that failed: the user may have stopped it and started another by the time the hop lands.
  private func endIfWritingFailed() {
    let failedSession = lock.withLock { () -> UUID? in
      guard let recording, recording.hasFailed, !isEndingAfterWriteFailure else { return nil }
      isEndingAfterWriteFailure = true
      return recording.sessionID
    }
    guard let failedSession else { return }
    Task { @MainActor [weak self] in
      guard let self, self.lock.withLock({ self.recording?.sessionID == failedSession }) else {
        return
      }
      self.end(because: .writeFailure)
    }
  }

  @MainActor
  private func end(because reason: WatchCaptureStopReason) {
    onStopped?(reason)
    if isRecording { stopRecording(reason: reason.rawValue) }
  }

  private func deliver(_ finished: (WatchSegmentMetadata, URL)) {
    guard let onSegmentFinished else { return }
    Task { @MainActor in onSegmentFinished(finished.0, finished.1) }
  }

  @MainActor
  private func pauseForInterruption() {
    guard engine != nil, isRecording else { return }
    stopEngine(deactivateSession: false)
    let (finished, failed) = lock.withLock {
      (recording?.close(), recording?.hasFailed == true)
    }
    // Persist this checkpoint before the OS can suspend the app.
    if let finished { onSegmentFinished?(finished.0, finished.1) }
    if failed {
      end(because: .writeFailure)
    } else {
      WatchDiagnostics.log("recording paused for audio interruption")
      onInterruptionBegan?()
    }
  }

  @MainActor
  private func observeInterruptions() {
    guard removeInterruptionObservers == nil else { return }
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    #if compiler(>=6.4)
    if #available(watchOS 27, *) {
      let inactive = center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
        guard case .systemInterruption = message.deactivationResult else { return }
        self?.pauseForInterruption()
      }
      let resume = center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
        guard message.recommendation == .shouldResume else { return }
        self?.onInterruptionEnded?()
      }
      removeInterruptionObservers = {
        center.removeObserver(inactive)
        center.removeObserver(resume)
      }
      return
    }
    #endif
    let legacy = center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: session,
      queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      MainActor.assumeIsolated {
        switch type {
        case .began: self?.pauseForInterruption()
        case .ended: self?.onInterruptionEnded?()
        @unknown default: break
        }
      }
    }
    removeInterruptionObservers = { center.removeObserver(legacy) }
  }
}
