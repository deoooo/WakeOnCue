@preconcurrency import AVFoundation
import Foundation

/// Captures a standalone sample of the device owner's voice for enrollment.
/// The sample is kept in memory only and handed over once on `stop()`.
final class VoiceEnrollmentRecorder: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?
  private var pcm = Data()
  private var peakLevel: Float = 0
  private var running = false

  /// Seconds of audio captured so far.
  var capturedDuration: TimeInterval {
    lock.withLock {
      Double(pcm.count / MemoryLayout<Int16>.size) / AudioCaptureService.sampleRate
    }
  }

  /// Loudest input level since the previous call, from 0 to 1.
  func consumeLevel() -> Float {
    lock.withLock {
      let level = peakLevel
      peakLevel = 0
      return level
    }
  }

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .default, options: AudioCaptureService.recordingCategoryOptions)
    try session.setPreferredSampleRate(AudioCaptureService.sampleRate)
    try session.setActive(true)

    let input = engine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureService.sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw AudioCaptureError.invalidInputFormat
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw AudioCaptureError.converterUnavailable
    }
    lock.withLock {
      self.converter = converter
      self.outputFormat = outputFormat
      pcm.removeAll()
      peakLevel = 0
      running = true
    }
    input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      lock.withLock { running = false }
      throw error
    }
  }

  /// Stops capturing and returns 24 kHz mono 16-bit PCM; the recorder keeps no copy.
  func stop() -> Data {
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return lock.withLock {
      running = false
      let captured = pcm
      pcm = Data()
      return captured
    }
  }

  private func process(_ inputBuffer: AVAudioPCMBuffer) {
    lock.withLock {
      guard running, let converter, let outputFormat else { return }
      let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
      let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 16
      guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
      else { return }
      let converterInput = OneShotConverterInput(buffer: inputBuffer)
      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        converterInput.provide(status: inputStatus)
      }
      guard status != .error, conversionError == nil, outputBuffer.frameLength > 0,
        let samples = outputBuffer.floatChannelData?[0],
        let data = AudioCaptureService.pcm16LittleEndianData(from: outputBuffer)
      else { return }
      pcm.append(data)

      let count = Int(outputBuffer.frameLength)
      var sumOfSquares: Float = 0
      for index in 0..<count { sumOfSquares += samples[index] * samples[index] }
      let rms = (sumOfSquares / Float(count)).squareRoot()
      let decibels = 20 * log10(max(rms, 0.000_01))
      peakLevel = max(peakLevel, min(1, max(0, (decibels + 60) / 60)))
    }
  }
}
