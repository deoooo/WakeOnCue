@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog

/// Re-transcribes Apple speech's sentences with the downloaded model, one sentence at a time.
/// Apple speech keeps doing the live transcript and its sentence boundaries act as the voice
/// activity detection; the better text replaces the live one, while times and speakers stay.
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
  @ObservationIgnored private var queue: [Sentence] = []
  @ObservationIgnored private var running = false
  @ObservationIgnored private var generation = 0

  init(store: Store) {
    self.store = store
  }

  /// Seconds of work per minute of audio, once something was processed.
  var secondsPerMinute: Double? {
    audioSeconds > 5 ? workSeconds / audioSeconds * 60 : nil
  }

  /// Loads the model in the background, or drops it for Apple speech alone. The transcription
  /// service needs no loading.
  func use(_ model: ASRModel?, service: TranscriptionServiceConfig? = nil) {
    generation += 1
    let current = generation
    recognizer = nil
    queue = []
    pending = 0
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
    queue.append(sentence)
    pending = queue.count
    start()
  }

  /// "用 Qwen3-ASR 重新转录": every sentence of the hour, again.
  func retranscribe(_ interval: DateInterval) {
    guard status != .off else { return }
    queue += store.sentences(in: interval)
    pending = queue.count
    start()
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
      // Wait for the model to finish loading.
      guard let recognizer, let modelName else {
        if case .loading = status {
          try? await Task.sleep(for: .seconds(1))
          continue
        }
        queue = []
        break
      }
      let sentence = queue.removeFirst()
      pending = queue.count
      let wait = sentence.end.addingTimeInterval(Self.settle).timeIntervalSinceNow
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      // Private and deleted time never goes to a model, and never leaves this Mac.
      if store.marks(overlapping: DateInterval(start: sentence.start, end: max(sentence.end, sentence.start))).contains(where: { $0.covers(sentence.start) }) {
        continue
      }
      let segments = store.segments(overlapping: DateInterval(start: sentence.start.addingTimeInterval(-Self.margin), end: sentence.end.addingTimeInterval(Self.margin)))
        .filter { $0.channel == sentence.channel }
      let start = sentence.start.addingTimeInterval(-Self.margin)
      let end = sentence.end.addingTimeInterval(Self.margin)
      let began = Date()
      let samples = await Task.detached(priority: .utility) { Self.samples(from: segments, start: start, end: end) }.value
      guard samples.count > 1_600 else { continue }
      let text: String
      do {
        text = try await recognizer.recognize(samples)
        lastError = nil
      } catch {
        lastError = error.localizedDescription
        Self.logger.error("Re-transcription failed: \(error.localizedDescription, privacy: .public)")
        continue
      }
      audioSeconds += end.timeIntervalSince(start)
      workSeconds += Date().timeIntervalSince(began)
      let cleaned = Self.clean(text)
      if !cleaned.isEmpty, cleaned != sentence.text {
        store.refineSentence(id: sentence.id, text: cleaned, by: modelName)
      }
    }
    pending = 0
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
