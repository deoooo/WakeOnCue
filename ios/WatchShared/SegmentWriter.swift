import AVFoundation
import Foundation

/// How much failing audio a recording tolerates before it has to end. Counted in seconds of audio
/// rather than wall-clock time, so the same audio always gives the same decision.
///
/// A short hiccup should not end a long recording, because the Watch cannot restart capture from
/// the background. Success pays failures back slowly, so failures that keep alternating with
/// successes still end the recording instead of silently losing a share of the audio forever.
struct SegmentFailureBudget: Equatable, Sendable {
  static let limitSeconds: TimeInterval = 5
  /// Seconds of failure repaid per second of success. Losing more than about 9% of the audio for
  /// long enough ends the recording.
  static let recoveryRate = 0.1

  private(set) var failedSeconds: TimeInterval = 0

  var isExhausted: Bool { failedSeconds >= Self.limitSeconds }

  mutating func recordFailure(seconds: TimeInterval) {
    failedSeconds += seconds
  }

  mutating func recordSuccess(seconds: TimeInterval) {
    failedSeconds = max(0, failedSeconds - seconds * Self.recoveryRate)
  }
}

/// The part of `AVAudioFile` the writer uses, so tests can make it fail on demand.
protocol SegmentFile: AnyObject {
  func write(from buffer: AVAudioPCMBuffer) throws
  func close()
}

extension AVAudioFile: SegmentFile {}

/// Writes consecutive fixed-length AAC files. Owned by `WatchAudioRecorder` under its lock.
///
/// The next file is opened before the full one is closed: while it cannot be opened, audio keeps
/// going into the current file, so that failure loses nothing. Once `hasFailed` is true the writer
/// takes no more audio and the owner has to end the recording; `close()` then saves what it can.
struct SegmentWriter {
  static let sampleRate = 16_000.0
  static let segmentDuration: TimeInterval = 60

  static var aacSettings: [String: Any] { [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 32_000,
  ] }

  typealias FileFactory = (URL, AVAudioFormat) throws -> any SegmentFile

  let sessionID: UUID
  let directory: URL
  private let segmentDuration: TimeInterval
  private let makeFile: FileFactory
  private let log: (String) -> Void
  private var file: (any SegmentFile)?
  private var url: URL?
  private var index = 0
  private var startedAt = Date()
  private var frames: AVAudioFramePosition = 0
  private var budget = SegmentFailureBudget()
  private(set) var completedCount = 0
  private(set) var recordedDuration: TimeInterval = 0
  private(set) var hasFailed = false

  init(
    sessionID: UUID,
    directory: URL,
    segmentDuration: TimeInterval = SegmentWriter.segmentDuration,
    makeFile: @escaping FileFactory = SegmentWriter.makeAACFile,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.sessionID = sessionID
    self.directory = directory
    self.segmentDuration = segmentDuration
    self.makeFile = makeFile
    self.log = log
  }

  static func makeAACFile(url: URL, format: AVAudioFormat) throws -> any SegmentFile {
    try AVAudioFile(
      forWriting: url,
      settings: aacSettings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
  }

  mutating func openNext(format: AVAudioFormat) throws {
    install(try makeNext(format: format))
  }

  /// Appends audio and returns the segment that just filled up, if any.
  mutating func write(_ pcm: AVAudioPCMBuffer, format: AVAudioFormat) -> (WatchSegmentMetadata, URL)? {
    guard let file, !hasFailed else { return nil }
    let seconds = Double(pcm.frameLength) / Self.sampleRate
    do {
      try file.write(from: pcm)
    } catch {
      noteFailure("segment write failed: \(error.localizedDescription)", seconds: seconds)
      return nil
    }
    frames += AVAudioFramePosition(pcm.frameLength)
    recordedDuration += seconds
    guard Double(frames) / Self.sampleRate >= segmentDuration else {
      budget.recordSuccess(seconds: seconds)
      return nil
    }
    let next: NextSegment
    do {
      next = try makeNext(format: format)
    } catch {
      noteFailure("segment open failed: \(error.localizedDescription)", seconds: seconds)
      return nil
    }
    guard let finished = close() else {
      next.file.close()
      try? FileManager.default.removeItem(at: next.url)
      return nil
    }
    budget.recordSuccess(seconds: seconds)
    install(next)
    return finished
  }

  /// Closes the open file. A file that cannot be read back is removed and not counted: the iPhone
  /// could never assemble a recording that includes it.
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
    guard Self.isReadable(url) else {
      log("segment unreadable after close: \(url.lastPathComponent)")
      try? FileManager.default.removeItem(at: url)
      hasFailed = true
      return nil
    }
    completedCount = index
    let metadata = WatchSegmentMetadata(
      sessionID: sessionID,
      index: index,
      startedAt: startedAt,
      duration: Double(frames) / Self.sampleRate
    )
    return (metadata, url)
  }

  // MARK: - Private

  private struct NextSegment {
    let file: any SegmentFile
    let url: URL
    let startedAt: Date
  }

  /// `index` moves only in `install`, so a failed attempt never leaves a gap in the numbering.
  private func makeNext(format: AVAudioFormat) throws -> NextSegment {
    let metadata = WatchSegmentMetadata(
      sessionID: sessionID, index: index + 1, startedAt: Date(), duration: 0)
    let url = directory.appending(path: metadata.fileName)
    do {
      return NextSegment(
        file: try makeFile(url, format), url: url, startedAt: metadata.startedAt)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  private mutating func install(_ next: NextSegment) {
    index += 1
    file = next.file
    url = next.url
    startedAt = next.startedAt
    frames = 0
  }

  private mutating func noteFailure(_ description: String, seconds: TimeInterval) {
    if budget.failedSeconds == 0 { log(description) }
    budget.recordFailure(seconds: seconds)
    guard budget.isExhausted else { return }
    log("segment writer giving up after \(Int(budget.failedSeconds))s: \(description)")
    hasFailed = true
  }

  private static func isReadable(_ url: URL) -> Bool {
    guard let file = try? AVAudioFile(forReading: url) else { return false }
    return file.length > 0
  }
}
