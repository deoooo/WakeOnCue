@preconcurrency import AVFoundation
import CryptoKit
import Foundation

struct CapturedAudioChunk: Sendable {
  let index: Int
  let url: URL
  let checksum: String
  let size: Int64
  let startedAt: Date
  let duration: TimeInterval
}

enum AudioCaptureError: Error, LocalizedError {
  case invalidInputFormat
  case converterUnavailable
  case conversionFailed(String)
  case setupFailed(stage: String, detail: String)
  case notRunning

  var errorDescription: String? {
    switch self {
    case .invalidInputFormat:
      AppLanguage.localized("The microphone returned an invalid audio format.")
    case .converterUnavailable:
      AppLanguage.localized("Unable to create the microphone format converter.")
    case .conversionFailed:
      AppLanguage.localized("Audio conversion failed. Please try again.")
    case .setupFailed(let stage, _):
      String(
        format: AppLanguage.localized("Could not %@. Please try again."),
        Self.localizedSetupStage(stage)
      )
    case .notRunning:
      AppLanguage.localized("No recording is active.")
    }
  }

  private static func localizedSetupStage(_ stage: String) -> String {
    let key: String.LocalizationValue =
      switch stage {
      case "setCategory": "configure recording mode"
      case "setPreferredSampleRate": "set the audio sample rate"
      case "setPreferredIOBufferDuration": "set the audio buffer"
      case "setActive": "activate the iPhone audio session"
      case "createSourceFile": "create the recording file"
      case "createFirstChunk": "create the first recording segment"
      case "engineStart": "start the recording engine"
      case "openTestFixture": "open the test audio file"
      default: "finish audio setup"
      }
    return AppLanguage.localized(key)
  }
}

private final class OneShotConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

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

final class AudioCaptureService: @unchecked Sendable {
  static let sampleRate = 24_000.0
  static let chunkDuration: TimeInterval = 10

  let chunks: AsyncStream<CapturedAudioChunk>

  private let engine = AVAudioEngine()
  private let recordingID: String
  private let fileLayout: RecordingFileLayout
  private let testFixtureURL: URL?
  private let lock = NSLock()
  private let chunkContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?
  private var sourceFile: AVAudioFile?
  private var chunkFile: AVAudioFile?
  private var chunkURL: URL?
  private var chunkStartedAt = Date()
  private var currentChunkFrames: AVAudioFramePosition = 0
  private var totalFrames: AVAudioFramePosition = 0
  private var nextChunkIndex = 1
  private var nextRealtimeSequence = 1
  private var realtimePCMBuffer = Data()
  private var realtimeSentFrames: AVAudioFramePosition = 0
  private var running = false
  private var paused = false
  private var interruptionObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var testFixtureTask: Task<Void, Never>?
  private var isUsingTestFixture = false

  var onInterruptionChanged: (@Sendable (_ isInterrupted: Bool, _ resumed: Bool) -> Void)?
  var onCaptureError: (@Sendable (Error) -> Void)?
  var onRealtimeAudioFrame: (@Sendable (RealtimeAudioFrame) -> Void)?

  init(
    recordingID: String,
    fileLayout: RecordingFileLayout,
    testFixtureURL: URL? = nil
  ) {
    self.recordingID = recordingID
    self.fileLayout = fileLayout
    self.testFixtureURL = testFixtureURL
    var continuation: AsyncStream<CapturedAudioChunk>.Continuation!
    chunks = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    chunkContinuation = continuation
  }

  deinit {
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
  }

  func start() throws {
    if let testFixtureURL {
      try startTestFixture(at: testFixtureURL)
      return
    }

    let session = AVAudioSession.sharedInstance()
    try setup("setCategory") {
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothHFP]
      )
    }
    try setup("setPreferredSampleRate") {
      try session.setPreferredSampleRate(Self.sampleRate)
    }
    try setup("setPreferredIOBufferDuration") {
      try session.setPreferredIOBufferDuration(0.02)
    }
    try setup("setActive") {
      try session.setActive(true)
    }

    let input = engine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw AudioCaptureError.invalidInputFormat
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw AudioCaptureError.converterUnavailable
    }
    self.outputFormat = outputFormat
    self.converter = converter
    sourceFile = try setup("createSourceFile") { try makeSourceFile(format: outputFormat) }
    try setup("createFirstChunk") { try openNextChunk(format: outputFormat) }
    installObservers()

    input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }
    engine.prepare()
    lock.withLock {
      running = true
      paused = false
    }
    do {
      try setup("engineStart") { try engine.start() }
    } catch {
      lock.withLock { running = false }
      input.removeTap(onBus: 0)
      throw error
    }
  }

  private func setup<T>(_ stage: String, _ action: () throws -> T) throws -> T {
    do {
      return try action()
    } catch {
      throw AudioCaptureError.setupFailed(stage: stage, detail: String(reflecting: error))
    }
  }

  func pause() throws {
    guard lock.withLock({ running && !paused }) else { throw AudioCaptureError.notRunning }
    if !isUsingTestFixture { engine.pause() }
    lock.withLock {
      paused = true
      finishCurrentChunkLocked()
      finishRealtimeFrameLocked()
    }
  }

  func resume() throws {
    guard lock.withLock({ running && paused }) else { throw AudioCaptureError.notRunning }
    guard let outputFormat else { throw AudioCaptureError.invalidInputFormat }
    try lock.withLock {
      if chunkFile == nil { try openNextChunkLocked(format: outputFormat) }
    }
    if !isUsingTestFixture {
      try AVAudioSession.sharedInstance().setActive(true)
      try engine.start()
    }
    lock.withLock { paused = false }
  }

  func stop() throws {
    guard lock.withLock({ running }) else { throw AudioCaptureError.notRunning }
    let wasUsingTestFixture = isUsingTestFixture
    testFixtureTask?.cancel()
    testFixtureTask = nil
    if !wasUsingTestFixture {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    lock.withLock {
      running = false
      paused = false
      finishCurrentChunkLocked()
      finishRealtimeFrameLocked()
      sourceFile = nil
      converter = nil
      outputFormat = nil
      isUsingTestFixture = false
    }
    chunkContinuation.finish()
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
      self.interruptionObserver = nil
    }
    if let routeObserver {
      NotificationCenter.default.removeObserver(routeObserver)
      self.routeObserver = nil
    }
    if !wasUsingTestFixture {
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        onCaptureError?(error)
      }
    }
  }

  var duration: TimeInterval {
    lock.withLock { Double(totalFrames) / Self.sampleRate }
  }

  private func startTestFixture(at url: URL) throws {
    let fixture = try setup("openTestFixture") { try AVAudioFile(forReading: url) }
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: fixture.processingFormat, to: outputFormat)
    else {
      throw AudioCaptureError.converterUnavailable
    }

    self.outputFormat = outputFormat
    self.converter = converter
    sourceFile = try setup("createSourceFile") { try makeSourceFile(format: outputFormat) }
    try setup("createFirstChunk") { try openNextChunk(format: outputFormat) }
    lock.withLock {
      running = true
      paused = false
      isUsingTestFixture = true
    }
    testFixtureTask = Task { [weak self] in
      await self?.streamTestFixture(fixture)
    }
  }

  private func streamTestFixture(_ fixture: AVAudioFile) async {
    let framesPerRead: AVAudioFrameCount = 2_048
    while !Task.isCancelled {
      let state = lock.withLock { (running, paused) }
      guard state.0 else { return }
      if state.1 {
        try? await Task.sleep(for: .milliseconds(50))
        continue
      }
      guard fixture.framePosition < fixture.length else { return }
      let remaining = fixture.length - fixture.framePosition
      let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(framesPerRead), remaining))
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: fixture.processingFormat,
          frameCapacity: frameCount
        )
      else {
        onCaptureError?(AudioCaptureError.invalidInputFormat)
        return
      }
      do {
        try fixture.read(into: buffer, frameCount: frameCount)
      } catch {
        onCaptureError?(error)
        return
      }
      process(buffer)
      let seconds = Double(buffer.frameLength) / fixture.processingFormat.sampleRate
      try? await Task.sleep(for: .seconds(seconds))
    }
  }

  private func process(_ inputBuffer: AVAudioPCMBuffer) {
    lock.withLock {
      guard running, !paused, let converter, let outputFormat else { return }
      let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
      let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 16
      guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
      else {
        return
      }
      let converterInput = OneShotConverterInput(buffer: inputBuffer)
      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        converterInput.provide(status: inputStatus)
      }
      guard status != .error, conversionError == nil else {
        onCaptureError?(
          AudioCaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown"))
        return
      }
      guard outputBuffer.frameLength > 0 else { return }
      do {
        try sourceFile?.write(from: outputBuffer)
        try chunkFile?.write(from: outputBuffer)
        let frames = AVAudioFramePosition(outputBuffer.frameLength)
        currentChunkFrames += frames
        totalFrames += frames
        if onRealtimeAudioFrame != nil,
          let pcm = Self.pcm16LittleEndianData(from: outputBuffer)
        {
          realtimePCMBuffer.append(pcm)
          emitFullRealtimeFramesLocked()
        }
        if Double(currentChunkFrames) / Self.sampleRate >= Self.chunkDuration {
          finishCurrentChunkLocked()
          try openNextChunkLocked(format: outputFormat)
        }
      } catch {
        onCaptureError?(error)
      }
    }
  }

  private func emitFullRealtimeFramesLocked() {
    let framesPerMessage = Int(Self.sampleRate / 2)
    let bytesPerMessage = framesPerMessage * MemoryLayout<Int16>.size
    while realtimePCMBuffer.count >= bytesPerMessage {
      let data = Data(realtimePCMBuffer.prefix(bytesPerMessage))
      realtimePCMBuffer.removeFirst(bytesPerMessage)
      emitRealtimeFrameLocked(data, frameCount: framesPerMessage)
    }
  }

  private func finishRealtimeFrameLocked() {
    guard !realtimePCMBuffer.isEmpty else { return }
    let frameCount = realtimePCMBuffer.count / MemoryLayout<Int16>.size
    let data = realtimePCMBuffer
    realtimePCMBuffer.removeAll(keepingCapacity: true)
    emitRealtimeFrameLocked(data, frameCount: frameCount)
  }

  private func emitRealtimeFrameLocked(_ data: Data, frameCount: Int) {
    guard let onRealtimeAudioFrame else { return }
    let startMilliseconds = Int(Double(realtimeSentFrames) / Self.sampleRate * 1_000)
    onRealtimeAudioFrame(
      RealtimeAudioFrame(
        sequence: nextRealtimeSequence,
        startMilliseconds: startMilliseconds,
        pcm16LittleEndian: data
      )
    )
    realtimeSentFrames += AVAudioFramePosition(frameCount)
    nextRealtimeSequence += 1
  }

  private static func pcm16LittleEndianData(from buffer: AVAudioPCMBuffer) -> Data? {
    guard let source = buffer.floatChannelData?[0] else { return nil }
    let count = Int(buffer.frameLength)
    var data = Data(count: count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { rawBuffer in
      let destination = rawBuffer.bindMemory(to: Int16.self)
      for index in 0..<count {
        let sample = max(-1, min(1, source[index]))
        destination[index] = Int16(sample * Float(Int16.max)).littleEndian
      }
    }
    return data
  }

  private func makeSourceFile(format: AVAudioFormat) throws -> AVAudioFile {
    let url = try fileLayout.sourceAudioURL(recordingID: recordingID)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Self.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: true,
    ]
    let file = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: format.commonFormat,
      interleaved: false
    )
    try RecordingFileLayout.protect(url)
    return file
  }

  private func openNextChunk(format: AVAudioFormat) throws {
    try lock.withLock { try openNextChunkLocked(format: format) }
  }

  private func openNextChunkLocked(format: AVAudioFormat) throws {
    let url = try fileLayout.chunkURL(recordingID: recordingID, index: nextChunkIndex)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: Self.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    chunkFile = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: format.commonFormat,
      interleaved: false
    )
    try RecordingFileLayout.protect(url)
    chunkURL = url
    chunkStartedAt = Date()
    currentChunkFrames = 0
  }

  private func finishCurrentChunkLocked() {
    guard currentChunkFrames > 0, let url = chunkURL else {
      chunkFile = nil
      chunkURL = nil
      return
    }
    let index = nextChunkIndex
    let startedAt = chunkStartedAt
    let duration = Double(currentChunkFrames) / Self.sampleRate
    chunkFile = nil
    chunkURL = nil
    currentChunkFrames = 0
    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let size = Int64(data.count)
      chunkContinuation.yield(
        CapturedAudioChunk(
          index: index,
          url: url,
          checksum: checksum,
          size: size,
          startedAt: startedAt,
          duration: duration
        )
      )
      nextChunkIndex += 1
    } catch {
      onCaptureError?(error)
    }
  }

  private func installObservers() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: nil
    ) { [weak self] notification in
      self?.handleInterruption(notification)
    }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: nil
    ) { [weak self] _ in
      guard let self, self.lock.withLock({ self.running && !self.paused }) else { return }
      if !self.engine.isRunning {
        do { try self.engine.start() } catch { self.onCaptureError?(error) }
      }
    }
  }

  private func handleInterruption(_ notification: Notification) {
    guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }
    switch type {
    case .began:
      do {
        try pause()
        onInterruptionChanged?(true, false)
      } catch {
        onCaptureError?(error)
      }
    case .ended:
      let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(
        .shouldResume)
      guard shouldResume else {
        onInterruptionChanged?(false, false)
        return
      }
      do {
        try resume()
        onInterruptionChanged?(false, true)
      } catch {
        onCaptureError?(error)
      }
    @unknown default:
      break
    }
  }
}
