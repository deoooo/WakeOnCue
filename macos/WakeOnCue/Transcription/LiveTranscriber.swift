@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

/// A finished stretch of speech with wall-clock times.
nonisolated struct RecognizedSentence: Sendable {
  let channel: AudioChannel
  let start: Date
  let end: Date
  let text: String
}

/// Text that may still change, for the live line in the menu bar and the current hour.
nonisolated struct VolatileText: Sendable {
  let channel: AudioChannel
  let start: Date
  let text: String
}

/// Live Mandarin transcription of one channel with SpeechAnalyzer. Audio is fed with explicit
/// start times, so pauses and gaps keep the timeline right. Final results are split into
/// sentences at sentence-ending punctuation, using the per-run audio time ranges.
nonisolated final class LiveTranscriber: @unchecked Sendable {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Transcriber")
  static let locale = Locale(identifier: "zh-CN")
  /// The analyzer's preferred input format, found by `prepare()`.
  nonisolated(unsafe) private static var preferredFormat: AVAudioFormat?

  let channel: AudioChannel
  private let onSentence: @Sendable (RecognizedSentence) -> Void
  private let onVolatile: @Sendable (VolatileText?) -> Void

  private let lock = NSLock()
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var epoch: Date?
  private var converter: AVAudioConverter?
  private var analyzerFormat: AVAudioFormat?
  private var session: Task<Void, Never>?
  private var sessionNumber = 0
  private var lastFed: Date?
  /// Analyzer timeline position of the next sample; input must never step back.
  private var nextSample: Int64 = 0

  init(
    channel: AudioChannel,
    onSentence: @escaping @Sendable (RecognizedSentence) -> Void,
    onVolatile: @escaping @Sendable (VolatileText?) -> Void
  ) {
    self.channel = channel
    self.onSentence = onSentence
    self.onVolatile = onVolatile
  }

  /// Makes sure the Mandarin model is on this Mac. Returns a reason when it cannot be used.
  /// `onDownload` gets the download progress when the model is not on this Mac yet.
  static func prepare(onDownload: @escaping @MainActor (Double) -> Void = { _ in }) async -> String? {
    guard SpeechTranscriber.isAvailable else { return "这台 Mac 不支持 Apple 语音转录" }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
      return "Apple 语音不支持中文转录"
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    do {
      // The system keeps only a few locales per app; claim this one so it is not evicted.
      if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
        _ = try? await AssetInventory.reserve(locale: locale)
      }
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        let progress = request.progress
        let watcher = Task { @MainActor in
          while !Task.isCancelled {
            onDownload(progress.fractionCompleted)
            try? await Task.sleep(for: .milliseconds(500))
          }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
      }
    } catch {
      return "中文语音模型下载失败：\(error.localizedDescription)"
    }
    preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    return nil
  }

  /// Called from the capture queue. Starts an analyzer session on the first buffer after a gap.
  func feed(_ timed: TimedBuffer) {
    lock.lock()
    defer { lock.unlock() }
    if let lastFed, timed.start.timeIntervalSince(lastFed) > 30 {
      // A long gap (pause, sleep): finish the session so its last words are finalized.
      finishLocked()
    }
    if continuation == nil { startLocked(at: timed.start) }
    lastFed = timed.start.addingTimeInterval(timed.duration)
    guard let continuation, let epoch, let analyzerFormat, let buffer = convert(timed.buffer, to: analyzerFormat) else { return }
    let rate = analyzerFormat.sampleRate
    let startSample = max(nextSample, Int64((timed.start.timeIntervalSince(epoch) * rate).rounded()))
    nextSample = startSample + Int64(buffer.frameLength)
    let offset = CMTime(value: startSample, timescale: CMTimeScale(rate))
    continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: offset))
  }

  /// Ends the session; the analyzer finalizes what it already heard.
  func finish() {
    lock.withLock { finishLocked() }
  }

  private func finishLocked() {
    continuation?.finish()
    continuation = nil
    epoch = nil
    lastFed = nil
    nextSample = 0
  }

  /// A failed session stops taking audio; the next buffer starts a fresh one.
  private func sessionEnded(_ number: Int) {
    lock.withLock {
      if number == sessionNumber, continuation != nil { finishLocked() }
    }
  }

  private func startLocked(at start: Date) {
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(2_000))
    self.continuation = continuation
    epoch = start
    nextSample = 0
    sessionNumber += 1
    let number = sessionNumber
    let transcriber = SpeechTranscriber(
      locale: Self.locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: [.audioTimeRange])
    analyzerFormat = Self.preferredFormat
      ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)
    let channel = channel
    let onSentence = onSentence
    let onVolatile = onVolatile
    let previous = session
    session = Task.detached(priority: .userInitiated) {
      await previous?.value
      let analyzer = SpeechAnalyzer(modules: [transcriber])
      let results = Task {
        do {
          for try await result in transcriber.results {
            if result.isFinal {
              for sentence in Self.sentences(in: result.text, channel: channel, epoch: start) {
                onSentence(sentence)
              }
              onVolatile(nil)
            } else {
              let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
              onVolatile(text.isEmpty ? nil : VolatileText(
                channel: channel, start: start.addingTimeInterval(result.range.start.seconds), text: text))
            }
          }
        } catch {
          Self.logger.error("Results failed: \(error.localizedDescription, privacy: .public)")
        }
      }
      do {
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      } catch {
        Self.logger.error("Analyzer failed: \(error.localizedDescription, privacy: .public)")
        await analyzer.cancelAndFinishNow()
      }
      await results.value
      onVolatile(nil)
      self.sessionEnded(number)
    }
  }

  private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    if buffer.format == format { return buffer }
    if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
      converter = AVAudioConverter(from: buffer.format, to: format)
    }
    guard let converter else { return nil }
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
    return status == .error || output.frameLength == 0 ? nil : output
  }

  /// Splits a final result into sentences, timing each from the runs it contains.
  static func sentences(in text: AttributedString, channel: AudioChannel, epoch: Date) -> [RecognizedSentence] {
    let enders: Set<Character> = ["。", "？", "！", "?", "!", "；", ";"]
    var sentences: [RecognizedSentence] = []
    var current = ""
    var start: Double?
    var end: Double?

    func flush() {
      let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, let start {
        sentences.append(RecognizedSentence(
          channel: channel,
          start: epoch.addingTimeInterval(start),
          end: epoch.addingTimeInterval(max(start, end ?? start)),
          text: trimmed))
      }
      current = ""
      start = nil
      end = nil
    }

    for run in text.runs {
      let piece = String(text[run.range].characters)
      if let range = run.audioTimeRange {
        if start == nil { start = range.start.seconds }
        end = range.end.seconds
      }
      for character in piece {
        current.append(character)
        if enders.contains(character) { flush() }
      }
    }
    flush()
    return sentences.filter { !$0.text.allSatisfy { enders.contains($0) || $0 == "，" || $0 == "," } }
  }
}

/// Apple speech on one stored sentence, for "重新转录" when no downloaded model is in use: the
/// same engine as the live transcript, but it hears the whole sentence at once.
nonisolated struct AppleSentenceRecognizer: SentenceRecognizer {
  /// The samples' format, as `Refiner.samples` reads them from the segment files.
  static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

  struct Unavailable: LocalizedError {
    var errorDescription: String? { "Apple 语音现在不可用" }
  }

  @concurrent nonisolated func recognize(_ samples: [Float]) async throws -> String {
    let transcriber = SpeechTranscriber(locale: LiveTranscriber.locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
      let input = Self.buffer(samples, format: format)
    else { throw Unavailable() }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let results = Task {
      var text = ""
      for try await result in transcriber.results where result.isFinal {
        text += String(result.text.characters)
      }
      return text
    }
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuation.yield(AnalyzerInput(buffer: input))
    continuation.finish()
    do {
      try await analyzer.start(inputSequence: stream)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      await analyzer.cancelAndFinishNow()
      results.cancel()
      throw error
    }
    return try await results.value
  }

  /// The samples in the analyzer's format.
  private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = source.floatChannelData?[0]
    else { return nil }
    source.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
    if format == inputFormat { return source }
    guard let converter = AVAudioConverter(from: inputFormat, to: format) else { return nil }
    let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / inputFormat.sampleRate) + 1_024
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return source
    }
    return status == .error || output.frameLength == 0 ? nil : output
  }
}
