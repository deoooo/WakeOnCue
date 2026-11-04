@preconcurrency import AVFoundation
import Foundation

/// The signal work behind merging: decoding to 16 kHz mono, laying the Mac's audio on a time
/// grid, comparing loudness envelopes to find the clock offset, and writing kept audio.
nonisolated enum AudioAlignment {
  static let sampleRate = 16_000.0
  /// Envelope frames of 20 ms.
  static let frame = 320

  /// The whole file as 16 kHz mono samples.
  static func samples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let input = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    if input.sampleRate == sampleRate, input.channelCount == 1, let data = buffer.floatChannelData?[0] {
      return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
    let output = ChannelPipeline.format
    guard let converter = AVAudioConverter(from: input, to: output) else { return [] }
    converter.downmix = true
    var result: [Float] = []
    var supplied = false
    while true {
      guard let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384) else { break }
      let status = converter.convert(to: chunk, error: nil) { _, state in
        if supplied {
          state.pointee = .endOfStream
          return nil
        }
        supplied = true
        state.pointee = .haveData
        return buffer
      }
      if let data = chunk.floatChannelData?[0] { result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength))) }
      if status == .endOfStream || status == .error || chunk.frameLength == 0 { break }
    }
    return result
  }

  /// The Mac's microphone audio from `start` for `count` samples, with silence where the Mac
  /// recorded nothing, and which samples it did record.
  static func macAudio(_ segments: [AudioSegment], start: Date, count: Int) -> (samples: [Float], covered: [Bool]) {
    var samples = [Float](repeating: 0, count: count)
    var covered = [Bool](repeating: false, count: count)
    for segment in segments {
      guard let file = try? AVAudioFile(forReading: Store.audioDirectory.appending(path: segment.path)) else { continue }
      let rate = file.processingFormat.sampleRate
      let into = Int((segment.start.timeIntervalSince(start) * sampleRate).rounded())
      let from = max(0, -into)
      let length = min(Int(Double(file.length) * sampleRate / rate) - from, count - max(0, into))
      guard length > 0, rate == sampleRate,
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length))
      else { continue }
      file.framePosition = AVAudioFramePosition(from)
      guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(length))) != nil, let data = buffer.floatChannelData?[0] else { continue }
      let offset = max(0, into)
      for index in 0..<Int(buffer.frameLength) where offset + index < count {
        samples[offset + index] = data[index]
        covered[offset + index] = true
      }
    }
    return (samples, covered)
  }

  /// Log loudness per 20 ms frame, which survives different microphones and gains.
  static func envelope(_ samples: [Float]) -> [Float] {
    stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
      var sum: Float = 0
      for index in start..<(start + frame) { sum += samples[index] * samples[index] }
      return log10(sqrt(sum / Float(frame)) + 1e-4)
    }
  }

  static func frames(_ covered: [Bool]) -> [Bool] {
    stride(from: 0, to: covered.count - frame + 1, by: frame).map { covered[$0 + frame / 2] }
  }

  /// The shift (in frames) that best lines up the remote envelope with the Mac's, searched
  /// within ±`maxLag`, as a Pearson correlation over frames the Mac recorded. `mac` starts
  /// `maxLag` frames before the remote audio's nominal start.
  static func bestLag(remote: [Float], mac: [Float], covered: [Bool], maxLag: Int) -> (lag: Int, correlation: Float, overlap: Int) {
    var best = (lag: 0, correlation: Float(-1), overlap: 0)
    for lag in -maxLag...maxLag {
      var xs: [Float] = []
      var ys: [Float] = []
      for index in remote.indices {
        let other = index + maxLag + lag
        guard other >= 0, other < mac.count, covered[other] else { continue }
        xs.append(remote[index])
        ys.append(mac[other])
      }
      guard xs.count >= 250 else { continue }
      let correlation = pearson(xs, ys)
      if correlation > best.correlation { best = (lag, correlation, xs.count) }
    }
    return best
  }

  static func pearson(_ xs: [Float], _ ys: [Float]) -> Float {
    let count = Float(xs.count)
    let meanX = xs.reduce(0, +) / count
    let meanY = ys.reduce(0, +) / count
    var covariance: Float = 0
    var varianceX: Float = 0
    var varianceY: Float = 0
    for index in xs.indices {
      let dx = xs[index] - meanX
      let dy = ys[index] - meanY
      covariance += dx * dy
      varianceX += dx * dx
      varianceY += dy * dy
    }
    let denominator = sqrt(varianceX * varianceY)
    return denominator > 0 ? covariance / denominator : 0
  }

  /// Writes samples as a 32 kbps AAC (ADTS) segment like the Mac's own.
  static func writeSegment(_ samples: [Float], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(forWriting: url, settings: ChannelPipeline.aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var offset = 0
    while offset < samples.count {
      let count = min(16_384, samples.count - offset)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: ChannelPipeline.format, frameCapacity: AVAudioFrameCount(count)) else { break }
      buffer.frameLength = AVAudioFrameCount(count)
      samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
      }
      try file.write(from: buffer)
      offset += count
    }
    file.close()
  }
}
