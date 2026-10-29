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

/// The Watch microphone pipeline. Audio is written as fixed-length AAC segments so a long
/// recording reaches the iPhone piece by piece and a crash loses at most the open segment.
final class WatchAudioRecorder: @unchecked Sendable {
  static let sampleRate = 16_000.0
  static let segmentDuration: TimeInterval = 60

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
  private(set) var isRunning = false

  /// Called on the main actor when the system stops capture (for example a phone call).
  var onStopped: (@MainActor @Sendable () -> Void)?
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
      var writer = SegmentWriter(sessionID: sessionID, directory: directory)
      try writer.openNext(format: outputFormat)
      recording = writer
    }
    WatchDiagnostics.log("recording started session=\(sessionID.uuidString.prefix(8))")
  }

  /// Closes the open segment and returns how many segments the recording has.
  @discardableResult
  func stopRecording(reason: String = "user") -> Int {
    let (finished, count) = lock.withLock { () -> ((WatchSegmentMetadata, URL)?, Int) in
      guard var writer = recording else { return (nil, 0) }
      let finished = writer.close()
      recording = nil
      return (finished, writer.completedCount)
    }
    if let finished { deliver(finished) }
    WatchDiagnostics.log("recording stopped reason=\(reason) segments=\(count)")
    stopEngine(reason: reason)
    return count
  }

  static var aacSettings: [String: Any] { [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 32_000,
  ] }

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
    let (heartbeat, finished) = lock.withLock { () -> (String?, (WatchSegmentMetadata, URL)?) in
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
        guard let self else { return }
        // watchOS cannot restart capture from the background, so end the recording cleanly.
        self.stopRecording(reason: "interruption")
        self.onStopped?()
      }
    }
  }
}

/// Writes consecutive fixed-length AAC files. Owned by `WatchAudioRecorder` under its lock.
private struct SegmentWriter {
  let sessionID: UUID
  let directory: URL
  private var file: AVAudioFile?
  private var url: URL?
  private var index = 0
  private var startedAt = Date()
  private var frames: AVAudioFramePosition = 0
  private(set) var completedCount = 0
  private(set) var recordedDuration: TimeInterval = 0

  init(sessionID: UUID, directory: URL) {
    self.sessionID = sessionID
    self.directory = directory
  }

  mutating func openNext(format: AVAudioFormat) throws {
    index += 1
    let metadata = WatchSegmentMetadata(sessionID: sessionID, index: index, startedAt: Date(), duration: 0)
    let url = directory.appending(path: metadata.fileName)
    file = try AVAudioFile(
      forWriting: url,
      settings: WatchAudioRecorder.aacSettings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    self.url = url
    startedAt = metadata.startedAt
    frames = 0
  }

  /// Appends audio and returns the segment that just filled up, if any.
  mutating func write(_ pcm: AVAudioPCMBuffer, format: AVAudioFormat) -> (WatchSegmentMetadata, URL)? {
    guard let file else { return nil }
    do {
      try file.write(from: pcm)
    } catch {
      WatchDiagnostics.log("segment write failed: \(error.localizedDescription)")
      return nil
    }
    frames += AVAudioFramePosition(pcm.frameLength)
    recordedDuration += Double(pcm.frameLength) / WatchAudioRecorder.sampleRate
    guard Double(frames) / WatchAudioRecorder.sampleRate >= WatchAudioRecorder.segmentDuration
    else { return nil }
    let finished = close()
    try? openNext(format: format)
    return finished
  }

  mutating func close() -> (WatchSegmentMetadata, URL)? {
    defer {
      file = nil
      url = nil
      frames = 0
    }
    guard let file, let url, frames > 0 else {
      if let url { try? FileManager.default.removeItem(at: url) }
      return nil
    }
    file.close()
    completedCount = index
    let metadata = WatchSegmentMetadata(
      sessionID: sessionID,
      index: index,
      startedAt: startedAt,
      duration: Double(frames) / WatchAudioRecorder.sampleRate
    )
    return (metadata, url)
  }
}

