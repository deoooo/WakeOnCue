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
  /// The system took the audio session (for example a phone call).
  case interruption
  /// Segments can no longer be opened or written (for example the Watch is out of storage).
  case writeFailure = "write_failure"
}

/// The Watch microphone pipeline. Audio is written as fixed-length AAC segments so a long
/// recording reaches the iPhone piece by piece and a crash loses at most the open segment.
final class WatchAudioRecorder: @unchecked Sendable {
  static let sampleRate = SegmentWriter.sampleRate
  static let segmentDuration = SegmentWriter.segmentDuration

  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: WatchAudioRecorder.sampleRate,
    channels: 1,
    interleaved: true
  )!
  private var converter: AVAudioConverter?
  private var interruptionObserver: NSObjectProtocol?
  private var level: Float = 0
  private var lastHeartbeat = Date.distantPast
  private var recording: SegmentWriter?
  /// Nil means the recording is written unchanged.
  private var silenceGate: WatchSilenceGate?
  private var gatedOutput: AVAudioPCMBuffer?
  private(set) var isRunning = false
  private var isEndingAfterWriteFailure = false

  /// Called on the main actor when capture has to end, while the recording is still open, so the
  /// handler's `stopRecording` returns a segment count that includes the last segment.
  var onStopped: (@MainActor @Sendable (WatchCaptureStopReason) -> Void)?
  /// Called on the main actor each time a recording segment is complete on disk.
  var onSegmentFinished: (@MainActor @Sendable (WatchSegmentMetadata, URL) -> Void)?

  init() {}

  deinit {
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
  }

  /// A smoothed 0...1 input level for the on-screen meter.
  var inputLevel: Float { lock.withLock { level } }

  var isRecording: Bool { lock.withLock { recording != nil } }

  /// Starts writing segments into `directory`. Must be called from a foreground user action:
  /// watchOS lets capture continue in the background but not start there.
  func startRecording(sessionID: UUID, directory: URL) async throws {
    try await startEngineIfNeeded()
    try lock.withLock {
      guard recording == nil else { return }
      isEndingAfterWriteFailure = false
      var writer = SegmentWriter(
        sessionID: sessionID, directory: directory, log: { WatchDiagnostics.log($0) })
      try writer.openNext(format: outputFormat)
      recording = writer
      // Allocated up front so a failure here means a full recording, not dropped audio later.
      gatedOutput = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096)
      silenceGate = gatedOutput == nil ? nil : WatchSilenceGate()
    }
    let gated = lock.withLock { silenceGate != nil }
    WatchDiagnostics.log(
      "recording started session=\(sessionID.uuidString.prefix(8)) silenceGate=\(gated)")
  }

  /// Closes the open segment and returns how many segments the recording has.
  @discardableResult
  func stopRecording(reason: String = "user") -> Int {
    let (finished, count, zeroed) = lock.withLock {
      () -> ([(WatchSegmentMetadata, URL)], Int, TimeInterval) in
      guard var writer = recording else { return ([], 0, 0) }
      var finished: [(WatchSegmentMetadata, URL)] = []
      var zeroed: TimeInterval = 0
      if var gate = silenceGate {
        finished += write(gate.flush(), to: &writer)
        zeroed = Double(gate.zeroedSamples) / Self.sampleRate
      }
      if let last = writer.close() { finished.append(last) }
      recording = nil
      silenceGate = nil
      gatedOutput = nil
      return (finished, writer.completedCount, zeroed)
    }
    finished.forEach(deliver)
    WatchDiagnostics.log(
      "recording stopped reason=\(reason) segments=\(count) silenceZeroed=\(Int(zeroed))s")
    stopEngine(reason: reason)
    return count
  }

  // MARK: - Engine

  private func startEngineIfNeeded() async throws {
    guard !isRunning else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      throw WatchAudioError.microphoneDenied
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)

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
    input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] pcm, _ in
      self?.process(pcm)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    isRunning = true
    observeInterruptions()
    WatchDiagnostics.log("engine started input=\(inputFormat.sampleRate)Hz")
  }

  private func stopEngine(reason: String) {
    guard isRunning else { return }
    WatchDiagnostics.log("engine stopped reason=\(reason)")
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isRunning = false
    lock.withLock { level = 0 }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
    let (heartbeat, finished) = lock.withLock { () -> (String?, [(WatchSegmentMetadata, URL)]) in
      level = max(instant, level * 0.8)
      var finished: [(WatchSegmentMetadata, URL)] = []
      if var writer = recording {
        if var gate = silenceGate {
          let ready = gate.process(samples)
          silenceGate = gate
          finished = write(ready, to: &writer)
        } else if let segment = writer.write(output, format: outputFormat) {
          finished = [segment]
        }
        recording = writer
      }
      guard Date().timeIntervalSince(lastHeartbeat) >= 15 else { return (nil, finished) }
      lastHeartbeat = Date()
      var recorded = recording.map { "recording=\(Int($0.recordedDuration))s" } ?? "idle"
      if let silenceGate {
        recorded += " silenceZeroed=\(Int(Double(silenceGate.zeroedSamples) / Self.sampleRate))s"
      }
      return (recorded, finished)
    }
    finished.forEach(deliver)
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
    if isRunning { stopRecording(reason: reason.rawValue) }
  }

  /// Writes samples released by the silence gate. Call with `lock` held.
  private func write(
    _ samples: [Int16], to writer: inout SegmentWriter
  ) -> [(WatchSegmentMetadata, URL)] {
    guard let gatedOutput, let channel = gatedOutput.int16ChannelData?[0] else { return [] }
    var finished: [(WatchSegmentMetadata, URL)] = []
    var next = 0
    while next < samples.count {
      let count = min(Int(gatedOutput.frameCapacity), samples.count - next)
      samples.withUnsafeBufferPointer { source in
        channel.update(from: source.baseAddress! + next, count: count)
      }
      gatedOutput.frameLength = AVAudioFrameCount(count)
      if let segment = writer.write(gatedOutput, format: outputFormat) { finished.append(segment) }
      next += count
    }
    return finished
  }

  private func deliver(_ finished: (WatchSegmentMetadata, URL)) {
    guard let onSegmentFinished else { return }
    Task { @MainActor in onSegmentFinished(finished.0, finished.1) }
  }

  private func observeInterruptions() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      WatchDiagnostics.log("audio interruption \(type == .began ? "began" : "ended")")
      guard type == .began else { return }
      MainActor.assumeIsolated {
        // watchOS cannot restart capture from the background, so end the recording cleanly.
        self?.end(because: .interruption)
      }
    }
  }
}
