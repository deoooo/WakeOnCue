@preconcurrency import AVFoundation
import Foundation

/// One conversation's audio as a single M4A for the iPhone, with the conversation's start at
/// zero so its transcript times line up. The Mac's own microphone is used wherever it recorded;
/// Watch or iPhone audio fills the rest. Private, deleted and paused time is silent, and gaps
/// between pieces are silence of the same length.
nonisolated enum ConversationAudio {
  struct Piece: Equatable {
    var segment: AudioSegment
    var range: DateInterval
  }

  static let sampleRate = 16_000.0

  static var cacheDirectory: URL {
    Store.rootDirectory.appending(path: "Cache/ConversationAudio", directoryHint: .isDirectory)
  }

  /// The same conversation and digest always give the same file, so a phone can resume.
  static func cachedURL(id: String, digest: String) -> URL {
    cacheDirectory.appending(path: "\(id)-\(digest.prefix(16)).m4a")
  }

  /// Which part of which segment plays when. Pure.
  static func plan(range: DateInterval, segments: [AudioSegment], hidden: [TimeMark]) -> [Piece] {
    var taken: [DateInterval] = hidden.compactMap { clip(DateInterval(start: $0.start, end: max($0.start, $0.end)), to: range) }
    var pieces: [Piece] = []
    let ordered = segments.filter { $0.channel != .remote }.sorted { $0.start < $1.start }
      + segments.filter { $0.channel == .remote }.sorted { $0.start < $1.start }
    for segment in ordered {
      guard segment.end > segment.start,
        let clipped = clip(DateInterval(start: segment.start, end: segment.end), to: range)
      else { continue }
      for part in subtract(taken, from: clipped) where part.duration >= 0.05 {
        pieces.append(Piece(segment: segment, range: part))
        taken.append(part)
      }
    }
    // Hidden time stays silent: it was only "taken" so that nothing plays there.
    return pieces.sorted { $0.range.start < $1.range.start }
  }

  static func render(_ pieces: [Piece], range: DateInterval, audioDirectory: URL, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Same extension, so AVAudioFile writes an M4A; renamed only once complete.
    let partial = url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent)
    try? FileManager.default.removeItem(at: partial)
    try write(pieces, range: range, audioDirectory: audioDirectory, to: partial)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: partial, to: url)
  }

  /// Returns once the file is closed.
  private static func write(_ pieces: [Piece], range: DateInterval, audioDirectory: URL, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    let output = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var written: AVAudioFramePosition = 0
    let frame = { (date: Date) in AVAudioFramePosition((date.timeIntervalSince(range.start) * sampleRate).rounded()) }

    for piece in pieces {
      try writeSilence(frame(piece.range.start) - written, to: output, format: format)
      written = max(written, frame(piece.range.start))
      let wanted = frame(piece.range.end) - written
      guard wanted > 0 else { continue }
      let source = try AVAudioFile(forReading: audioDirectory.appending(path: piece.segment.path))
      let samples = try read(source, from: piece.range.start.timeIntervalSince(piece.segment.start), count: wanted, as: format)
      if samples.frameLength > 0 { try output.write(from: samples) }
      written += AVAudioFramePosition(samples.frameLength)
      // A file shorter than its database span leaves silence, so later pieces stay in place.
      try writeSilence(frame(piece.range.end) - written, to: output, format: format)
      written = max(written, frame(piece.range.end))
    }
    try writeSilence(frame(range.end) - written, to: output, format: format)
  }

  /// `count` frames at 16 kHz mono starting `offset` seconds into `file`, converted if needed.
  private static func read(_ file: AVAudioFile, from offset: TimeInterval, count: AVAudioFramePosition, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let sourceFormat = file.processingFormat
    let ratio = sourceFormat.sampleRate / sampleRate
    let start = AVAudioFramePosition(max(0, offset) * sourceFormat.sampleRate)
    guard start < file.length else { return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)! }
    file.framePosition = start
    let sourceCount = AVAudioFrameCount(min(file.length - start, AVAudioFramePosition((Double(count) * ratio).rounded(.up))))
    let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: max(1, sourceCount))!
    try file.read(into: input, frameCount: sourceCount)
    if sourceFormat.sampleRate == format.sampleRate, sourceFormat.channelCount == 1,
      sourceFormat.commonFormat == .pcmFormatFloat32, !sourceFormat.isInterleaved
    {
      input.frameLength = min(input.frameLength, AVAudioFrameCount(count))
      return input
    }
    let converter = AVAudioConverter(from: sourceFormat, to: format)!
    let capacity = AVAudioFrameCount(count) + 1_024
    let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    var supplied = false
    var error: NSError?
    converter.convert(to: converted, error: &error) { _, status in
      if supplied { status.pointee = .endOfStream; return nil }
      supplied = true
      status.pointee = .haveData
      return input
    }
    if let error { throw error }
    converted.frameLength = min(converted.frameLength, AVAudioFrameCount(count))
    return converted
  }

  private static func writeSilence(_ frames: AVAudioFramePosition, to file: AVAudioFile, format: AVAudioFormat) throws {
    var left = frames
    while left > 0 {
      let count = AVAudioFrameCount(min(left, 16_000))
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
      buffer.frameLength = count
      if let channel = buffer.floatChannelData?[0] { channel.initialize(repeating: 0, count: Int(count)) }
      try file.write(from: buffer)
      left -= AVAudioFramePosition(count)
    }
  }

  private static func clip(_ interval: DateInterval, to range: DateInterval) -> DateInterval? {
    let start = max(interval.start, range.start)
    let end = min(interval.end, range.end)
    return end > start ? DateInterval(start: start, end: end) : nil
  }

  /// What is left of `interval` after taking out every range in `taken`.
  static func subtract(_ taken: [DateInterval], from interval: DateInterval) -> [DateInterval] {
    var parts = [interval]
    for cut in taken {
      parts = parts.flatMap { part -> [DateInterval] in
        guard cut.start < part.end, cut.end > part.start else { return [part] }
        var left: [DateInterval] = []
        if cut.start > part.start { left.append(DateInterval(start: part.start, end: cut.start)) }
        if cut.end < part.end { left.append(DateInterval(start: cut.end, end: part.end)) }
        return left
      }
    }
    return parts
  }
}
