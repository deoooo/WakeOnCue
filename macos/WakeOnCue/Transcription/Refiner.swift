@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog

/// Re-transcribes Apple speech's sentences with the downloaded model, one sentence at a time.
/// Apple speech keeps doing the live transcript and its sentence boundaries act as the voice
/// activity detection; the better text replaces the live one, while times and speakers stay.
///
/// "重新转录" runs a stretch of time again with whatever is chosen now: the downloaded model or
/// service, or Apple speech when none is. Once a stretch is done, the hours and meetings whose
/// words changed are handed to `onRetranscribed`, so their summaries follow the new words.
@Observable
final class Refiner {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Refiner")
  /// Wait this long after a sentence ends, so its audio is on disk.
  private static let settle: TimeInterval = 8
  /// A little audio around each sentence so the first and last words are not clipped.
  private static let margin: TimeInterval = 0.25

  enum Status: Equatable {
    case off
    case loading(String)
    case ready(String)
    case failed(String)
  }

  private(set) var status: Status = .off
  /// The latest failure of a sentence, e.g. the transcription service's HTTP error.
  private(set) var lastError: String?
  private(set) var pending = 0
  /// Seconds of audio processed and seconds it took, to tell whether it keeps up.
  private(set) var audioSeconds: Double = 0
  private(set) var workSeconds: Double = 0

  @ObservationIgnored private let store: Store
  @ObservationIgnored private var recognizer: (any SentenceRecognizer)?
  @ObservationIgnored private var modelName: String?
  /// Stretches being re-transcribed on request, for progress next to them.
  private(set) var retranscribing: [DateInterval] = []
  /// Sentences of those stretches still to do.
  private(set) var retranscribeRemaining = 0
  /// Starts of the sentences whose words changed in a finished stretch.
  @ObservationIgnored var onRetranscribed: (([Date]) -> Void)?

  private struct Job {
    var sentence: Sentence
    /// The stretch it was requested for; nil for a live sentence.
    var batch: DateInterval?
  }

  @ObservationIgnored private var queue: [Job] = []
  @ObservationIgnored private var changed: [DateInterval: [Date]] = [:]
  @ObservationIgnored private var running = false
  @ObservationIgnored private var generation = 0

  init(store: Store) {
    self.store = store
  }

  /// Seconds of work per minute of audio, once something was processed.
  var secondsPerMinute: Double? {
    audioSeconds > 5 ? workSeconds / audioSeconds * 60 : nil
  }

  /// What "重新转录" uses now.
  var retranscribeName: String {
    switch status {
    case .ready(let name), .loading(let name): name
    case .off, .failed: "Apple 语音"
    }
  }

  func isRetranscribing(_ interval: DateInterval) -> Bool {
    retranscribing.contains { $0.start < interval.end && interval.start < $0.end }
  }

  /// Loads the model in the background, or drops it for Apple speech alone. The transcription
  /// service needs no loading. Stretches asked for again carry on with the new choice.
  func use(_ model: ASRModel?, service: TranscriptionServiceConfig? = nil) {
    generation += 1
    let current = generation
    recognizer = nil
    modelName = nil
    queue.removeAll { $0.batch == nil }
    pending = queue.count
    lastError = nil
    if let model, model.isRemote, let service {
      recognizer = RemoteTranscriber(config: service)
      modelName = model.name
      status = .ready(model.name)
      return
    }
    guard let model, let files = ASRModels.files(of: model) else {
      status = .off
      modelName = nil
      return
    }
    status = .loading(model.name)
    Task {
      do {
        let loaded = try await Task.detached(priority: .utility) {
          try SherpaRecognizer(runtime: ASRModels.runtimeFolder, qwen3: files)
        }.value
        guard current == generation else { return }
        recognizer = loaded
        modelName = model.name
        status = .ready(model.name)
      } catch {
        guard current == generation else { return }
        status = .failed(error.localizedDescription)
        Self.logger.error("Model failed to load: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// A new live sentence; it is re-transcribed once its audio is on disk.
  func enqueue(_ sentence: Sentence) {
    guard modelName != nil || status != .off else { return }
    queue.append(Job(sentence: sentence))
    pending = queue.count
    start()
  }

  /// "重新转录": every sentence of the stretch again, with what is chosen now.
  func retranscribe(_ interval: DateInterval) {
    let queued = Set(queue.filter { $0.batch != nil }.map(\.sentence.id))
    let sentences = store.sentences(in: interval).filter { !queued.contains($0.id) }
    guard !sentences.isEmpty else { return }
    retranscribing.append(interval)
    queue += sentences.map { Job(sentence: $0, batch: interval) }
    pending = queue.count
    retranscribeRemaining = queue.count { $0.batch != nil }
    start()
  }

  /// Stops the stretches asked for; what already changed still updates its summaries.
  func cancelRetranscription() {
    queue.removeAll { $0.batch != nil }
    pending = queue.count
    for interval in retranscribing { finish(interval) }
  }

  private func finish(_ interval: DateInterval) {
    retranscribing.removeAll { $0 == interval }
    retranscribeRemaining = queue.count { $0.batch != nil }
    let starts = changed.removeValue(forKey: interval) ?? []
    if !starts.isEmpty { onRetranscribed?(starts) }
  }

  private func start() {
    guard !running else { return }
    running = true
    Task {
      await drain()
      running = false
    }
  }

  private func drain() async {
    while !queue.isEmpty {
      if recognizer == nil, case .loading = status {
        // Wait for the model to finish loading.
        try? await Task.sleep(for: .seconds(1))
        continue
      }
      let job = queue.removeFirst()
      pending = queue.count
      // Apple speech already wrote the live text; it only runs again when asked.
      let use: (recognizer: any SentenceRecognizer, name: String?)? =
        recognizer.map { ($0, modelName) } ?? (job.batch != nil ? (AppleSentenceRecognizer(), nil) : nil)
      if let use, let changedText = await refine(job.sentence, with: use.recognizer, name: use.name),
        changedText, let batch = job.batch {
        changed[batch, default: []].append(job.sentence.start)
      }
      if let batch = job.batch {
        retranscribeRemaining = queue.count { $0.batch != nil }
        if !queue.contains(where: { $0.batch == batch }) { finish(batch) }
      }
    }
    pending = 0
  }

  /// Runs one sentence again and stores the result. Returns whether its words changed, or nil
  /// when it was skipped or failed.
  private func refine(_ sentence: Sentence, with recognizer: any SentenceRecognizer, name modelName: String?) async -> Bool? {
    let wait = sentence.end.addingTimeInterval(Self.settle).timeIntervalSinceNow
    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    // Private and deleted time never goes to a model, and never leaves this Mac.
    if store.marks(overlapping: DateInterval(start: sentence.start, end: max(sentence.end, sentence.start))).contains(where: { $0.covers(sentence.start) }) {
      return nil
    }
    let segments = store.segments(overlapping: DateInterval(start: sentence.start.addingTimeInterval(-Self.margin), end: sentence.end.addingTimeInterval(Self.margin)))
      .filter { $0.channel == sentence.channel }
    let start = sentence.start.addingTimeInterval(-Self.margin)
    let end = sentence.end.addingTimeInterval(Self.margin)
    let began = Date()
    let samples = await Task.detached(priority: .utility) { Self.samples(from: segments, start: start, end: end) }.value
    guard samples.count > 1_600 else { return nil }
    let text: String
    do {
      text = try await recognizer.recognize(samples)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      Self.logger.error("Re-transcription failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
    if modelName != nil {
      audioSeconds += end.timeIntervalSince(start)
      workSeconds += Date().timeIntervalSince(began)
    }
    let cleaned = Self.clean(text)
    guard !cleaned.isEmpty else { return false }
    // Apple speech run again on a short sound (嗯, 对) can hear English ("you"); keep the
    // Chinese the live pass heard instead.
    if modelName == nil, !Self.hasChinese(cleaned), Self.hasChinese(sentence.text) { return false }
    // The current text may be gone: the sentence was deleted, or merged with a recording.
    guard let current = store.sentences(ids: [sentence.id]).first else { return nil }
    guard cleaned != current.text || modelName != current.refinedBy else { return false }
    store.refineSentence(id: sentence.id, text: cleaned, by: modelName)
    return cleaned != current.text
  }

  nonisolated static func hasChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
  }

  /// Qwen3-ASR sometimes prefixes the detected language; keep only the words.
  nonisolated static func clean(_ text: String) -> String {
    var result = text
    if let range = result.range(of: "<asr_text>") { result = String(result[range.upperBound...]) }
    if result.hasPrefix("language "), let space = result.dropFirst(9).firstIndex(where: { $0 == " " || $0 == "\n" }) {
      result = String(result[space...])
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 16 kHz mono samples between `start` and `end`, read from the segment files.
  nonisolated static func samples(from segments: [AudioSegment], start: Date, end: Date) -> [Float] {
    var samples: [Float] = []
    for segment in segments.sorted(by: { $0.start < $1.start }) {
      guard let file = try? AVAudioFile(forReading: Store.audioDirectory.appending(path: segment.path)) else { continue }
      let rate = file.processingFormat.sampleRate
      let from = AVAudioFramePosition(max(0, start.timeIntervalSince(segment.start)) * rate)
      let to = min(file.length, AVAudioFramePosition(max(0, end.timeIntervalSince(segment.start)) * rate))
      guard to > from, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(to - from)) else { continue }
      file.framePosition = from
      guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(to - from))) != nil,
        let data = buffer.floatChannelData?[0]
      else { continue }
      samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
    return samples
  }
}
