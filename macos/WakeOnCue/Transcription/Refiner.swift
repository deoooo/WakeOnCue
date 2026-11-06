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
///
/// Work that has not been done yet is kept in the database (`refine_attempts`, `refine_next`,
/// `refine_checked_by`), not only in the in-memory queue: a sweep after launch, after loading a
/// model, and every five minutes puts back whatever a restart or a failure left behind.
@Observable
final class Refiner {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Refiner")
  /// A little audio around each sentence so the first and last words are not clipped.
  private static let margin: TimeInterval = 0.25
  /// How often the background sweep looks for sentences still needing the chosen model.
  private static let sweepInterval: TimeInterval = 300
  /// The same hour is summarized again at most this often when the sweep repairs its sentences.
  private static let hourRegenerateInterval: TimeInterval = 600

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
  /// Stretches being re-transcribed on request.
  private(set) var retranscribing: [DateInterval] = []
  /// Starts of every sentence asked for, and of those not done yet: progress per hour.
  private(set) var requestedStarts: [Date] = []
  private(set) var waitingStarts: [Date] = []
  /// An hour whose sentences are all done and whose summary should be written again: its words
  /// changed, or the whole stretch was asked to be summarized again.
  @ObservationIgnored var onHourRetranscribed: ((Date) -> Void)?
  /// A finished or stopped stretch, the starts of the sentences whose words changed, and whether
  /// everything in it (meetings too) should be summarized again.
  @ObservationIgnored var onRetranscribed: ((DateInterval, [Date], Bool) -> Void)?
  @ObservationIgnored private var summarizeAll: Set<DateInterval> = []
  @ObservationIgnored private var batchStarts: [DateInterval: [Date]] = [:]
  @ObservationIgnored private var reportedHours: [DateInterval: Set<Date>] = [:]

  private struct Job {
    var sentence: Sentence
    /// The stretch it was requested for; nil for a live or sweep sentence.
    var batch: DateInterval?
    /// True for a sentence found by the background sweep, false for a live sentence.
    var swept = false
  }

  @ObservationIgnored private var queue: [Job] = []
  /// Sentence IDs in `queue` or currently being handled. Kept until a job finishes so the sweep
  /// cannot add a second copy of a slow sentence.
  @ObservationIgnored private var queuedIDs: Set<Int64> = []
  /// IDs being processed right now; a `retranscribe` request can promote them to a batch.
  @ObservationIgnored private var inFlightIDs: Set<Int64> = []
  /// Batch jobs that were in flight when the user asked to re-transcribe their interval.
  @ObservationIgnored private var promotedBatches: [Int64: DateInterval] = [:]
  /// Sentences whose batch was stopped: the sweep must not put them straight back.
  @ObservationIgnored private var suppressedIDs: Set<Int64> = []
  @ObservationIgnored private var batchIDs: [DateInterval: Set<Int64>] = [:]
  @ObservationIgnored private var changed: [DateInterval: [Date]] = [:]
  @ObservationIgnored private var running = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var sweepTask: Task<Void, Never>?
  /// When each hour was last handed to the summaries because a swept sentence changed.
  @ObservationIgnored private var recentHourRegenerations: [Date: Date] = [:]

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

  /// The share of the sentences in `interval` done so far, 0 while they wait their turn; nil
  /// when none of them is being re-transcribed, or all are done.
  func retranscribeProgress(in interval: DateInterval) -> Double? {
    let inside = { (date: Date) in date >= interval.start && date < interval.end }
    let left = waitingStarts.count(where: inside)
    guard left > 0 else { return nil }
    let total = requestedStarts.count(where: inside)
    return Double(max(total - left, 0)) / Double(max(total, 1))
  }

  /// Loads the model in the background, or drops it for Apple speech alone. The transcription
  /// service needs no loading. Stretches asked for again carry on with the new choice.
  func use(_ model: ASRModel?, service: TranscriptionServiceConfig? = nil) {
    generation += 1
    let current = generation
    recognizer = nil
    modelName = nil
    pending = queue.count
    lastError = nil
    if let model, model.isRemote, let service {
      recognizer = RemoteTranscriber(config: service)
      modelName = model.name
      status = .ready(model.name)
      startSweeping()
      start()
      return
    }
    guard let model, let files = ASRModels.files(of: model) else {
      status = .off
      modelName = nil
      sweepTask?.cancel()
      sweepTask = nil
      return
    }
    status = .loading(model.name)
    sweepTask?.cancel()
    sweepTask = nil
    Task {
      do {
        let loaded = try await Task.detached(priority: .utility) {
          try SherpaRecognizer(runtime: ASRModels.runtimeFolder, qwen3: files)
        }.value
        guard current == generation else { return }
        recognizer = loaded
        modelName = model.name
        status = .ready(model.name)
        startSweeping()
        start()
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
    guard !queuedIDs.contains(sentence.id) else { return }
    queuedIDs.insert(sentence.id)
    queue.append(Job(sentence: sentence))
    pending = queue.count
    start()
  }

  /// "重新转录": every sentence of the stretch again, with what is chosen now. With
  /// `summarizeAll`, every summary of the stretch is written again afterwards.
  func retranscribe(_ interval: DateInterval, summarizeAll all: Bool = false) {
    let sentences = store.sentences(in: interval)
    guard !sentences.isEmpty else { return }
    if !retranscribing.contains(interval) { retranscribing.append(interval) }
    if all { summarizeAll.insert(interval) }
    let already = batchIDs[interval] ?? []
    let fresh = sentences.filter { !already.contains($0.id) }
    guard !fresh.isEmpty else { return }
    let ids = Set(fresh.map(\.id))
    suppressedIDs.subtract(ids)
    let starts = fresh.map(\.start)
    batchStarts[interval, default: []] += starts
    batchIDs[interval, default: []].formUnion(ids)
    requestedStarts += starts
    waitingStarts += starts
    // A live or sweep job already in memory is promoted instead of queued twice.
    for index in queue.indices where ids.contains(queue[index].sentence.id) && queue[index].batch == nil {
      queue[index].batch = interval
    }
    for id in ids where inFlightIDs.contains(id) { promotedBatches[id] = interval }
    let absent = fresh.filter { !queuedIDs.contains($0.id) }
    for sentence in absent {
      queuedIDs.insert(sentence.id)
      queue.append(Job(sentence: sentence, batch: interval))
    }
    pending = queue.count
    start()
  }

  /// Stops the stretches asked for; what already changed still updates its summaries.
  func cancelRetranscription() {
    // Remember what was stopped: the sweep must not put it back on its own.
    for interval in retranscribing {
      if let ids = batchIDs[interval] { suppressedIDs.formUnion(ids) }
    }
    for job in queue where job.batch != nil { queuedIDs.remove(job.sentence.id) }
    queue.removeAll { $0.batch != nil }
    promotedBatches = promotedBatches.filter { !retranscribing.contains($0.value) }
    pending = queue.count
    waitingStarts = []
    for interval in retranscribing { finish(interval, stopped: true) }
  }

  /// Looks for sentences that still need the chosen model, e.g. after a crash or a failed try,
  /// and queues the ones not queued already.
  func sweep() {
    guard let modelName else { return }
    let sentences = store.sentencesNeedingRefinement(
      model: modelName, limit: 5_000, maxAttempts: RefineSchedule.maxAttempts)
    let fresh = sentences.filter { !queuedIDs.contains($0.id) && !suppressedIDs.contains($0.id) }
    guard !fresh.isEmpty else { return }
    for sentence in fresh { queuedIDs.insert(sentence.id) }
    queue += fresh.map { Job(sentence: $0, swept: true) }
    pending = queue.count
    start()
  }

  private func startSweeping() {
    sweepTask?.cancel()
    guard modelName != nil else { return }
    sweepTask = Task { [weak self] in
      guard let self else { return }
      self.sweep()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.sweepInterval))
        guard !Task.isCancelled else { return }
        self.sweep()
      }
    }
  }

  /// After a sentence of `batch`: once its hour has nothing left, that hour is summarized again.
  private func hourDone(_ start: Date, batch: DateInterval) {
    let calendar = Calendar.current
    let hour = calendar.hourStart(start)
    guard !queue.contains(where: { $0.batch == batch && calendar.hourStart($0.sentence.start) == hour }) else { return }
    reportedHours[batch, default: []].insert(hour)
    let changedHere = changed[batch]?.contains { calendar.hourStart($0) == hour } ?? false
    if changedHere || summarizeAll.contains(batch) { onHourRetranscribed?(hour) }
  }

  private func finish(_ interval: DateInterval, stopped: Bool = false) {
    retranscribing.removeAll { $0 == interval }
    batchStarts[interval] = nil
    batchIDs[interval] = nil
    for id in promotedBatches.filter({ $0.value == interval }).map(\.key) {
      promotedBatches[id] = nil
    }
    requestedStarts = batchStarts.values.flatMap { $0 }
    let starts = changed.removeValue(forKey: interval) ?? []
    // Stopped halfway: the hour it stopped in still gets its changes summarized.
    let reported = reportedHours.removeValue(forKey: interval) ?? []
    for hour in Set(starts.map(Calendar.current.hourStart)).subtracting(reported).sorted() {
      onHourRetranscribed?(hour)
    }
    let all = summarizeAll.remove(interval) != nil && !stopped
    onRetranscribed?(interval, starts, all)
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
    while true {
      while !queue.isEmpty {
        guard let job = takeNextJob() else {
          // No usable recognizer for the job(s) at hand: wait for a model instead of dropping
          // live sentences. A later `use()` or `retranscribe()` wakes this same loop.
          try? await Task.sleep(for: .seconds(1))
          continue
        }
        pending = queue.count
        // Apple speech already wrote the live text; it only runs again when asked. A live or
        // sweep job can be promoted to a batch while its recognition is already running.
        let initialBatch = job.batch ?? promotedBatches[job.sentence.id]
        let use: (recognizer: any SentenceRecognizer, name: String?)? =
          recognizer.map { ($0, modelName) } ?? (initialBatch != nil ? (AppleSentenceRecognizer(), nil) : nil)
        let changedText: Bool?
        if let use {
          changedText = await refine(job.sentence, with: use.recognizer, name: use.name)
        } else {
          changedText = nil
        }
        // A retranscribe request may have promoted this in-flight job while it was awaiting.
        let promoted = promotedBatches.removeValue(forKey: job.sentence.id)
        if changedText == true {
          let batch = job.batch ?? promoted
          if let batch {
            if retranscribing.contains(batch) {
              changed[batch, default: []].append(job.sentence.start)
            } else {
              // Finished after "停止": its hour was already handed over without it.
              onHourRetranscribed?(Calendar.current.hourStart(job.sentence.start))
            }
          } else if job.swept {
            // Only a sentence put back by the sweep needs its hour summarized again; a live
            // sentence is part of the normal summary flow.
            regenerateHourIfNeeded(job.sentence.start)
          }
        }
        let batch = job.batch ?? promoted
        if let batch, retranscribing.contains(batch) {
          if let index = waitingStarts.firstIndex(of: job.sentence.start) { waitingStarts.remove(at: index) }
          hourDone(job.sentence.start, batch: batch)
          if !queue.contains(where: { $0.batch == batch }), !promotedBatches.values.contains(batch) {
            finish(batch)
          }
        }
        queuedIDs.remove(job.sentence.id)
        inFlightIDs.remove(job.sentence.id)
      }
      pending = 0
      // A crash can leave thousands behind; keep sweeping until the library has no more for
      // this model, so one open does not wait five minutes per 5,000.
      sweep()
      if queue.isEmpty { break }
    }
  }

  /// The next job that can run now: live sentences first, then whatever else when a model is
  /// loaded; only "重新转录" jobs with Apple speech when no model is loaded. Live sentences wait
  /// for a model instead of being lost.
  private func takeNextJob() -> Job? {
    if recognizer != nil {
      let index = queue.firstIndex(where: { $0.batch == nil && !$0.swept }) ?? 0
      let job = queue.remove(at: index)
      inFlightIDs.insert(job.sentence.id)
      return job
    }
    if case .loading = status { return nil }
    guard let index = queue.firstIndex(where: { $0.batch != nil }) else { return nil }
    let job = queue.remove(at: index)
    inFlightIDs.insert(job.sentence.id)
    return job
  }

  /// Summarizes the hour of a live or swept sentence again, at most once per ten minutes.
  private func regenerateHourIfNeeded(_ start: Date) {
    let now = Date()
    recentHourRegenerations = recentHourRegenerations.filter {
      now.timeIntervalSince($0.value) < Self.hourRegenerateInterval
    }
    let hour = Calendar.current.hourStart(start)
    if let last = recentHourRegenerations[hour], now.timeIntervalSince(last) < Self.hourRegenerateInterval { return }
    recentHourRegenerations[hour] = now
    onHourRetranscribed?(hour)
  }

  /// Runs one sentence again and stores the result. Returns whether its words changed, or nil
  /// when it was skipped or failed.
  private func refine(_ sentence: Sentence, with recognizer: any SentenceRecognizer, name modelName: String?) async -> Bool? {
    let wait = sentence.end.addingTimeInterval(RefineSchedule.settle).timeIntervalSinceNow
    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    // Private and deleted time never goes to a model, and never leaves this Mac. Check the whole
    // sentence, not just its start: a mark may cover only part of it.
    let span = DateInterval(start: sentence.start, end: max(sentence.end, sentence.start))
    if store.marks(overlapping: span).contains(where: { $0.start < span.end && $0.end > span.start }) {
      return nil
    }
    let segments = store.segments(overlapping: DateInterval(start: sentence.start.addingTimeInterval(-Self.margin), end: sentence.end.addingTimeInterval(Self.margin)))
      .filter { $0.channel == sentence.channel }
    let start = sentence.start.addingTimeInterval(-Self.margin)
    let end = sentence.end.addingTimeInterval(Self.margin)
    let began = Date()
    let samples = await Task.detached(priority: .utility) { Self.samples(from: segments, start: start, end: end) }.value
    guard samples.count > 1_600 else {
      recordFailure(sentence)
      return nil
    }
    let text: String
    do {
      text = try await recognizer.recognize(samples)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      Self.logger.error("Re-transcription failed: \(error.localizedDescription, privacy: .public)")
      recordFailure(sentence)
      return nil
    }
    if modelName != nil {
      audioSeconds += end.timeIntervalSince(start)
      workSeconds += Date().timeIntervalSince(began)
    }
    let cleaned = Self.clean(text)
    // An empty or made-up reply (Apple speech hearing "you" in 嗯, Qwen3-ASR's "Hello, world.")
    // keeps the Chinese the live pass heard.
    guard TranscriptFilter.shouldReplace(live: sentence.text, with: cleaned) else {
      // The model looked at it and chose the live text: do not ask the same model again.
      if let modelName { store.markRefineChecked(id: sentence.id, model: modelName) }
      return false
    }
    // The current text may be gone: the sentence was deleted, or merged with a recording.
    guard let current = store.sentences(ids: [sentence.id]).first else { return nil }
    guard cleaned != current.text || modelName != current.refinedBy else { return false }
    store.refineSentence(id: sentence.id, text: cleaned, by: modelName)
    return cleaned != current.text
  }

  /// Counts a failed try from the latest database state and sets the next one with the
  /// 1 min / 10 min / 1 h backoff. Re-reading matters when a slow job was also queued twice.
  private func recordFailure(_ sentence: Sentence) {
    store.bumpRefineFailure(id: sentence.id)
  }

  /// The words of the model's reply, without its language tag, special tokens and the text it
  /// makes up after them.
  nonisolated static func clean(_ text: String) -> String {
    TranscriptFilter.cleanModelOutput(text)
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
