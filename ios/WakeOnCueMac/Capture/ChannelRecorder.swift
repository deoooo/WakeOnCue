@preconcurrency import AVFoundation
import Foundation
import WakeOnCueCore

struct RealtimeAudioFrame: Sendable {
  let sequence: Int
  let startMilliseconds: Int
  let pcm16LittleEndian: Data
}

/// One capture channel: converts whatever the device delivers to the realtime format
/// (24 kHz mono PCM16), writes it to a local CAF first, and only then hands 0.5 s frames
/// to the network. Disk writes never wait on the network.
final class ChannelRecorder: @unchecked Sendable {
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: Double(RealtimeProtocol.sampleRate),
    channels: AVAudioChannelCount(RealtimeProtocol.channels),
    interleaved: true
  )!
  private static let samplesPerFrame = RealtimeProtocol.sampleRate / 2

  let channel: RealtimeAudioChannel
  let fileURL: URL

  private let queue: DispatchQueue
  private let file: AVAudioFile
  private let recordingStart: Date
  private let onFrame: @Sendable (RealtimeAudioFrame) -> Void
  private var converter: AVAudioConverter?
  private var pending = Data()
  private var sequence = 1
  private var emittedSamples = 0
  private var writtenSamples = 0
  private var aligned = false
  private var closed = false
  private let levelLock = NSLock()
  private var latestLevel: Float = 0
  private var lastError: String?

  init(
    channel: RealtimeAudioChannel,
    fileURL: URL,
    recordingStart: Date,
    onFrame: @escaping @Sendable (RealtimeAudioFrame) -> Void
  ) throws {
    self.channel = channel
    self.fileURL = fileURL
    self.recordingStart = recordingStart
    self.onFrame = onFrame
    queue = DispatchQueue(label: "com.deoooo.WakeOnCue.mac.channel.\(channel.rawValue)")
    file = try AVAudioFile(
      forWriting: fileURL,
      settings: Self.format.settings,
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )
  }

  /// A 0...1 meter of the most recent buffer, for the menu bar.
  var level: Float {
    levelLock.withLock { latestLevel }
  }

  var failure: String? {
    levelLock.withLock { lastError }
  }

  var durationSeconds: Double {
    queue.sync { Double(writtenSamples) / Double(RealtimeProtocol.sampleRate) }
  }

  /// Called from capture callbacks. The buffer is copied before returning.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
    let level = Self.rmsLevel(copy)
    levelLock.withLock { latestLevel = level }
    queue.async { [self] in process(copy) }
  }

  /// Flushes the last partial frame and closes the file.
  func finish() {
    queue.sync {
      guard !closed else { return }
      closed = true
      if !pending.isEmpty { emitFrame(byteCount: pending.count) }
      file.close()
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard !closed else { return }
    if !aligned {
      aligned = true
      // Both channels share the recording's timeline: pad the start with silence so a
      // channel that delivered its first buffer later still lines up with the other.
      let offset = Int(Date().timeIntervalSince(recordingStart) * Double(RealtimeProtocol.sampleRate))
        - Int(buffer.frameLength) * RealtimeProtocol.sampleRate / Int(buffer.format.sampleRate)
      if offset > 0 { write(silenceSamples: offset) }
    }
    guard let converted = convert(buffer) else { return }
    write(converted)
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if converter == nil || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: Self.format)
      converter?.downmix = true
    }
    guard let converter else {
      record(error: String(localized: "Unsupported audio input format."))
      return nil
    }
    let ratio = Self.format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else {
      return nil
    }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if status == .error {
      record(error: conversionError?.localizedDescription ?? String(localized: "Audio conversion failed."))
      return nil
    }
    return output
  }

  private func write(silenceSamples count: Int) {
    var remaining = count
    while remaining > 0 {
      let chunk = min(remaining, RealtimeProtocol.sampleRate)
      guard let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(chunk))
      else { return }
      silence.frameLength = AVAudioFrameCount(chunk)
      memset(silence.int16ChannelData![0], 0, chunk * MemoryLayout<Int16>.size)
      write(silence)
      remaining -= chunk
    }
  }

  private func write(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return }
    do {
      try file.write(from: buffer)
      writtenSamples += Int(buffer.frameLength)
    } catch {
      // Keep streaming even if the disk write failed, but surface it loudly.
      record(error: error.localizedDescription)
    }
    pending.append(
      UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    let bytesPerFrame = Self.samplesPerFrame * MemoryLayout<Int16>.size
    while pending.count >= bytesPerFrame { emitFrame(byteCount: bytesPerFrame) }
  }

  private func emitFrame(byteCount: Int) {
    let data = Data(pending.prefix(byteCount))
    pending.removeFirst(byteCount)
    onFrame(
      RealtimeAudioFrame(
        sequence: sequence,
        startMilliseconds: emittedSamples * 1_000 / RealtimeProtocol.sampleRate,
        pcm16LittleEndian: data
      ))
    sequence += 1
    emittedSamples += byteCount / MemoryLayout<Int16>.size
  }

  private func record(error: String) {
    levelLock.withLock { lastError = error }
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
    else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
      guard let fromData = from.mData, let toData = to.mData else { continue }
      memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
    }
    return copy
  }

  private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    let count = Int(buffer.frameLength)
    if let samples = buffer.floatChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count { sum += samples[index] * samples[index] }
      return min(1, sqrt(sum / Float(max(count, 1))) * 4)
    }
    if let samples = buffer.int16ChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count {
        let value = Float(samples[index]) / Float(Int16.max)
        sum += value * value
      }
      return min(1, sqrt(sum / Float(max(count, 1))) * 4)
    }
    return 0
  }
}
