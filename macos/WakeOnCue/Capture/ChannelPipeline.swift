@preconcurrency import AVFoundation
import Foundation

/// 16 kHz mono audio with the wall-clock time of its first sample.
nonisolated struct TimedBuffer: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  let start: Date

  var duration: TimeInterval { Double(buffer.frameLength) / buffer.format.sampleRate }
}

nonisolated enum SegmentEvent: Sendable {
  case opened(channel: AudioChannel, path: String, start: Date, source: String)
  case closed(path: String, end: Date, source: String)
  case failed(String)
}

/// One capture channel. Converts whatever the device delivers to 16 kHz mono, writes it to
/// clock-aligned five-minute AAC segments (32 kbps), and hands the same audio to the
/// transcriber. Segments are ADTS streams, which stay readable if the app dies mid-file. Capture callbacks only copy the buffer; everything else runs on its queue.
nonisolated final class ChannelPipeline: @unchecked Sendable {
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  static let segmentLength: TimeInterval = 300
  static var aacSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
  }

  let channel: AudioChannel
  private let queue: DispatchQueue
  private let onSegment: @Sendable (SegmentEvent) -> Void
  private let onAudio: @Sendable (TimedBuffer) -> Void
  /// Called when a meeting segment closes or the channel stops, so live transcription can
  /// finalize the words it was holding in volatile results.
  private let onIdle: @Sendable () -> Void
  /// Meeting audio is written only when it is actually audible; the microphone is always recorded.
  private let gateEnabled: Bool
  private let audioDirectory: URL

  private var converter: AVAudioConverter?
  private var file: AVAudioFile?
  private var filePath: String?
  private var fileEnd: Date = .distantPast
  /// Wall-clock time of the next sample, kept by counting samples so segments stay gapless.
  private var clock: Date?
  private var writtenEnd: Date?
  private var running = false
  /// Recent buffers kept for the two seconds before the first sound of a meeting segment.
  private var preRoll: [(buffer: AVAudioPCMBuffer, start: Date)] = []
  private var preRollSeconds: TimeInterval = 0
  private var gate = MeetingAudioGate()

  private let lock = NSLock()
  private var latestLevel: Float = 0
  private var lastAudibleAt: Date?
  /// Actual audible buffer ranges, so callers can tell whether a sentence really had sound
  /// rather than merely sharing a five-minute segment with it.
  private var audibleRanges: [(start: Date, end: Date)] = []
  private var measuredFrom: Date?
  private var measuredTo: Date?
  private var currentSource: String
  /// Recent loudness, ten values a second, so the transcriber can tell a near voice from a far one.
  private var loudness: [(Date, Float)] = []

  init(
    channel: AudioChannel,
    source: String,
    directory: URL = Store.audioDirectory,
    onSegment: @escaping @Sendable (SegmentEvent) -> Void,
    onAudio: @escaping @Sendable (TimedBuffer) -> Void,
    onIdle: @escaping @Sendable () -> Void = {}
  ) {
    self.channel = channel
    self.currentSource = source
    self.audioDirectory = directory
    self.onSegment = onSegment
    self.onAudio = onAudio
    self.onIdle = onIdle
    gateEnabled = channel == .meeting
    queue = DispatchQueue(label: "com.deoooo.WakeOnCue.macos.pipeline.\(channel.rawValue)", qos: .userInitiated)
  }

  var level: Float { lock.withLock { latestLevel } }

  /// The last time a buffer on this channel was louder than the silence floor.
  var lastSoundAt: Date? { lock.withLock { lastAudibleAt } }

  /// Whether this channel had audible audio between `start` and `end`, or nil when that range
  /// is older than the in-memory history. Used for the "in a meeting" decision.
  func hadSound(from start: Date, to end: Date) -> Bool? {
    lock.withLock {
      guard let measuredFrom, let measuredTo, start >= measuredFrom, end <= measuredTo else { return nil }
      return audibleRanges.contains { $0.start < end && $0.end > start }
    }
  }

  var source: String {
    get { lock.withLock { currentSource } }
    set { lock.withLock { currentSource = newValue } }
  }

  /// Mean loudness (0...1) over a time range, or nil if nothing was measured.
  func loudness(from start: Date, to end: Date) -> Float? {
    lock.withLock {
      let values = loudness.filter { $0.0 >= start && $0.0 <= end }.map(\.1)
      guard !values.isEmpty else { return nil }
      return values.reduce(0, +) / Float(values.count)
    }
  }

  func start() {
    queue.async { [self] in
      running = true
      clock = nil
    }
  }

  /// Closes the open segment. Audio arriving afterwards is dropped until `start()`.
  func stop() {
    queue.sync {
      running = false
      closeFile()
      gate.reset()
      preRoll.removeAll()
      preRollSeconds = 0
      clock = nil
    }
    lock.withLock {
      latestLevel = 0
      lastAudibleAt = nil
      audibleRanges.removeAll()
      measuredFrom = nil
      measuredTo = nil
    }
    onIdle()
  }

  /// Called from capture threads; the buffer is copied before returning.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
    let arrival = Date()
    queue.async { [self] in process(copy, arrival: arrival) }
  }

  private func process(_ buffer: AVAudioPCMBuffer, arrival: Date) {
    guard running, let converted = convert(buffer) else { return }
    let duration = Double(converted.frameLength) / Self.format.sampleRate
    // Re-anchor on the wall clock after a stall (sleep, device change) or drift over a second.
    let measured = arrival.addingTimeInterval(-duration)
    var start = clock ?? measured
    if abs(start.timeIntervalSince(measured)) > 1 { start = measured }
    clock = start.addingTimeInterval(duration)

    let audible = measure(converted, start: start)
    if gateEnabled {
      switch gate.process(duration: duration, silent: !audible) {
      case .skip:
        rememberPreRoll(converted, start: start)
      case .open:
        writeWithPreRoll(converted, start: start)
      case .append:
        write(converted, start: start)
      case .appendAndClose:
        write(converted, start: start, allowOpen: false)
        closeFile()
        onIdle()
      }
      // Silence never reaches transcription: a muted meeting app produces no sentences.
      guard audible else { return }
    } else {
      write(converted, start: start)
    }
    onAudio(TimedBuffer(buffer: converted, start: start))
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if converter == nil || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: Self.format)
      converter?.downmix = true
    }
    guard let converter else { return nil }
    let ratio = Self.format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }

  /// Records loudness and returns whether this buffer has any sound above the silence floor.
  private func measure(_ buffer: AVAudioPCMBuffer, start: Date) -> Bool {
    guard let samples = buffer.floatChannelData?[0] else { return false }
    let count = Int(buffer.frameLength)
    let step = 1_600
    var values: [(Date, Float)] = []
    var total: Float = 0
    var peak: Float = 0
    var offset = 0
    while offset < count {
      let end = min(count, offset + step)
      var sum: Float = 0
      for index in offset..<end {
        sum += samples[index] * samples[index]
        peak = max(peak, abs(samples[index]))
      }
      let rms = sqrt(sum / Float(max(1, end - offset)))
      total = max(total, rms)
      values.append((start.addingTimeInterval(Double(offset) / Self.format.sampleRate), rms))
      offset = end
    }
    let audible = !AudioLevel.isSilent(peak)
    let bufferEnd = start.addingTimeInterval(Double(count) / Self.format.sampleRate)
    lock.withLock {
      latestLevel = min(1, total * 5)
      if audible {
        lastAudibleAt = Date()
        audibleRanges.append((start, bufferEnd))
        if audibleRanges.count > 6_000 { audibleRanges.removeFirst(audibleRanges.count - 6_000) }
      }
      measuredFrom = min(measuredFrom ?? start, start)
      measuredTo = max(measuredTo ?? bufferEnd, bufferEnd)
      loudness.append(contentsOf: values)
      if loudness.count > 6_000 { loudness.removeFirst(loudness.count - 6_000) }
    }
    return audible
  }

  private func rememberPreRoll(_ buffer: AVAudioPCMBuffer, start: Date) {
    preRoll.append((buffer, start))
    preRollSeconds += Double(buffer.frameLength) / Self.format.sampleRate
    while preRollSeconds > MeetingAudioGate.preRoll, preRoll.count > 1 {
      let first = preRoll.removeFirst()
      preRollSeconds -= Double(first.buffer.frameLength) / Self.format.sampleRate
    }
  }

  /// Opens a segment on the first sound and writes the recent pre-roll before this buffer, so the
  /// first word is not cut off.
  private func writeWithPreRoll(_ buffer: AVAudioPCMBuffer, start: Date) {
    let buffers = preRoll + [(buffer, start)]
    preRoll.removeAll()
    preRollSeconds = 0
    guard let first = buffers.first else { return }
    openFile(at: first.start, alignedTo: start)
    for item in buffers { write(item.buffer, start: item.start) }
  }

  private func write(_ buffer: AVAudioPCMBuffer, start: Date, allowOpen: Bool = true) {
    if file == nil {
      guard allowOpen else { return }
      openFile(at: start)
    } else if start >= fileEnd {
      closeFile()
      guard allowOpen else { return }
      openFile(at: start)
    }
    guard let file else { return }
    do {
      try file.write(from: buffer)
      writtenEnd = start.addingTimeInterval(Double(buffer.frameLength) / Self.format.sampleRate)
    } catch {
      onSegment(.failed("录音写入失败：\(error.localizedDescription)"))
    }
  }

  private func openFile(at start: Date, alignedTo align: Date? = nil) {
    closeFile()
    let calendar = Calendar.current
    let anchor = align ?? start
    let day = calendar.startOfDay(for: anchor)
    let sinceMidnight = anchor.timeIntervalSince(day)
    fileEnd = day.addingTimeInterval((floor(sinceMidnight / Self.segmentLength) + 1) * Self.segmentLength)

    let path = "\(TimeText.dayFolder(start))/\(channel.rawValue)-\(TimeText.fileStamp(start)).aac"
    let url = audioDirectory.appending(path: path)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      file = try AVAudioFile(
        forWriting: url, settings: Self.aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
      filePath = path
      onSegment(.opened(channel: channel, path: path, start: start, source: source))
    } catch {
      file = nil
      filePath = nil
      onSegment(.failed("无法创建录音文件：\(error.localizedDescription)"))
    }
  }

  private func closeFile() {
    guard let file, let filePath else { return }
    let end = writtenEnd ?? Date()
    file.close()
    writtenEnd = nil
    self.file = nil
    self.filePath = nil
    onSegment(.closed(path: filePath, end: end, source: source))
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
      guard let fromData = from.mData, let toData = to.mData else { continue }
      memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
    }
    return copy
  }
}
