@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog

/// Puts Watch and iPhone audio received from a phone into the Mac's timeline.
///
/// Each segment is placed at its real start time and compared with the Mac's microphone over
/// the same minutes: loudness envelopes are cross-correlated within ±3 seconds, which finds how
/// far the phone's clock is off and whether both heard the same thing. Same content: the Mac's
/// audio is kept and only the stretches the Mac did not record are added. Different content
/// (or merging turned off): the segment is kept alongside. Paused, private and deleted time is
/// dropped. Kept audio becomes ordinary segments and is transcribed like the rest.
@Observable
final class Merger {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Merge")
  /// Correlation at or above this means both devices heard the same conversation.
  nonisolated static let sameContentCorrelation: Float = 0.5
  /// How far apart the clocks may be.
  nonisolated static let maxLagSeconds = 3.0
  /// Comparing needs at least this much audio the Mac also recorded.
  nonisolated static let minimumOverlapSeconds = 10.0
  /// Shorter gaps are not worth a segment of their own.
  nonisolated static let minimumFillSeconds = 1.0

  private(set) var isWorking = false
  private(set) var lastOutcome: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private let summaries: Summaries
  @ObservationIgnored private var running = false
  @ObservationIgnored private var transcribers: [LiveTranscriber] = []

  init(store: Store, preferences: Preferences, summaries: Summaries) {
    self.store = store
    self.preferences = preferences
    self.summaries = summaries
  }

  /// Merges every received segment not merged yet, oldest first. One run at a time.
  func mergePending() async {
    guard !running else { return }
    running = true
    isWorking = true
    defer {
      running = false
      isWorking = false
    }
    while let segment = store.unmergedRemoteSegments().first {
      await merge(segment)
    }
  }

  // MARK: Clock offsets

  /// Seconds to add to a device's timestamps, learned from earlier overlaps.
  private func clockOffset(for device: String) -> TimeInterval {
    (UserDefaults.standard.dictionary(forKey: "clockOffsets") as? [String: Double])?[device] ?? 0
  }

  private func learn(_ offset: TimeInterval, for device: String) {
    var offsets = (UserDefaults.standard.dictionary(forKey: "clockOffsets") as? [String: Double]) ?? [:]
    // Moves slowly, so one bad match does not throw later segments off.
    offsets[device] = offsets[device].map { $0 * 0.7 + offset * 0.3 } ?? offset
    UserDefaults.standard.set(offsets, forKey: "clockOffsets")
  }

  // MARK: Merging

  private struct Run {
    var start: Date
    var samples: ArraySlice<Float>
  }

  private func merge(_ segment: Store.RemoteSegment) async {
    let url = SyncServer.inbox.appending(path: segment.path)
    let known = clockOffset(for: segment.device)
    let maxLag = Int(Self.maxLagSeconds * AudioAlignment.sampleRate) / AudioAlignment.frame
    let windowStart = segment.start.addingTimeInterval(known - Self.maxLagSeconds)
    let macSegments = store.segments(overlapping: DateInterval(
      start: windowStart, duration: segment.duration + 2 * Self.maxLagSeconds + 1)).filter { $0.channel == .microphone }

    let analysis = await Task.detached(priority: .utility) { () -> (samples: [Float], lag: Int, correlation: Float, overlap: Int, macCovered: [Bool])? in
      guard let samples = try? AudioAlignment.samples(of: url), !samples.isEmpty else { return nil }
      let count = samples.count + Int(2 * Self.maxLagSeconds * AudioAlignment.sampleRate)
      let mac = AudioAlignment.macAudio(macSegments, start: windowStart, count: count)
      let coveredFrames = AudioAlignment.frames(mac.covered)
      let best = AudioAlignment.bestLag(
        remote: AudioAlignment.envelope(samples), mac: AudioAlignment.envelope(mac.samples), covered: coveredFrames, maxLag: maxLag)
      return (samples, best.lag, best.correlation, best.overlap, coveredFrames)
    }.value
    guard let analysis else {
      store.finishRemoteSegment(id: segment.id, outcome: "unreadable", clockOffset: nil)
      return
    }

    let frameSeconds = Double(AudioAlignment.frame) / AudioAlignment.sampleRate
    let enoughOverlap = Double(analysis.overlap) * frameSeconds >= Self.minimumOverlapSeconds
    let same = enoughOverlap && analysis.correlation >= Self.sameContentCorrelation && preferences.mergeSameContent
    var runs: [Run] = []
    var offset = known
    let outcome: String
    if same {
      offset = known + Double(analysis.lag) * frameSeconds
      learn(offset, for: segment.device)
      // Keep only the frames where the Mac recorded nothing.
      let start = segment.start.addingTimeInterval(offset)
      var runStart: Int?
      let remoteFrames = analysis.samples.count / AudioAlignment.frame
      for index in 0...remoteFrames {
        let macFrame = index + maxLag + analysis.lag
        let macHas = index < remoteFrames && macFrame >= 0 && macFrame < analysis.macCovered.count && analysis.macCovered[macFrame]
        let open = index < remoteFrames && !macHas
        if open, runStart == nil { runStart = index }
        if !open, let first = runStart {
          if Double(index - first) * frameSeconds >= Self.minimumFillSeconds {
            let from = first * AudioAlignment.frame
            let to = min(analysis.samples.count, index * AudioAlignment.frame)
            runs.append(Run(start: start.addingTimeInterval(Double(from) / AudioAlignment.sampleRate), samples: analysis.samples[from..<to]))
          }
          runStart = nil
        }
      }
      outcome = runs.isEmpty ? "duplicate" : "filled"
    } else {
      runs = [Run(start: segment.start.addingTimeInterval(known), samples: analysis.samples[...])]
      outcome = analysis.overlap == 0 ? "filled" : "kept"
    }

    runs = runs.flatMap(excludeMarked)
    if runs.isEmpty, outcome != "duplicate" {
      store.finishRemoteSegment(id: segment.id, outcome: "dropped", clockOffset: offset)
      return
    }
    let label = segment.source == "watch" ? "Apple Watch" : "iPhone"
    for run in runs {
      keep(run, label: label)
    }
    store.finishRemoteSegment(id: segment.id, outcome: outcome, clockOffset: offset)
    let summary = "\(label) \(TimeText.clock(segment.start)) 的一段：" + [
      "duplicate": "和 Mac 录到的相同，保留 Mac 的音频",
      "filled": "补上了 Mac 没录到的 \(Int(runs.reduce(0) { $0 + Double($1.samples.count) } / AudioAlignment.sampleRate)) 秒",
      "kept": "和 Mac 录到的不同，两边都保留",
    ][outcome, default: outcome]
    lastOutcome = summary
    Self.logger.notice(
      "\(segment.id, privacy: .public): \(outcome, privacy: .public), lag \(analysis.lag) frames, r \(analysis.correlation), overlap \(analysis.overlap) frames, offset \(offset)")
  }

  /// Splits a run around paused, private and deleted time.
  private func excludeMarked(_ run: Run) -> [Run] {
    let duration = Double(run.samples.count) / AudioAlignment.sampleRate
    let marks = store.marks(overlapping: DateInterval(start: run.start, duration: max(duration, 0.001)))
    guard !marks.isEmpty else { return [run] }
    var pieces: [Run] = []
    var pieceStart: Int?
    let step = AudioAlignment.frame
    for index in stride(from: 0, through: run.samples.count, by: step) {
      let time = run.start.addingTimeInterval(Double(index) / AudioAlignment.sampleRate)
      let open = index < run.samples.count && !marks.contains { $0.covers(time) }
      if open, pieceStart == nil { pieceStart = index }
      if !open, let first = pieceStart {
        let base = run.samples.startIndex
        let to = min(run.samples.count, index)
        if Double(to - first) / AudioAlignment.sampleRate >= Self.minimumFillSeconds {
          pieces.append(Run(start: run.start.addingTimeInterval(Double(first) / AudioAlignment.sampleRate), samples: run.samples[(base + first)..<(base + to)]))
        }
        pieceStart = nil
      }
    }
    return pieces
  }

  /// Writes the run as a segment of its own and transcribes it.
  private func keep(_ run: Run, label: String) {
    let end = run.start.addingTimeInterval(Double(run.samples.count) / AudioAlignment.sampleRate)
    let path = "\(TimeText.dayFolder(run.start))/remote-\(TimeText.fileStamp(run.start))-\(UUID().uuidString.prefix(4)).aac"
    do {
      try AudioAlignment.writeSegment(Array(run.samples), to: Store.audioDirectory.appending(path: path))
    } catch {
      Self.logger.error("Could not write merged audio: \(error.localizedDescription, privacy: .public)")
      return
    }
    let id = store.insertSegment(channel: .remote, start: run.start, path: path, source: label)
    store.finishSegment(id: id, end: end, source: label)

    let store = store
    let transcriber = LiveTranscriber(
      channel: .remote,
      onSentence: { sentence in
        Task { @MainActor in
          // The Watch and the iPhone are with the user, so their voice is "我" by default.
          store.insertSentence(start: sentence.start, end: sentence.end, channel: .remote, speaker: .me, source: label, text: sentence.text)
        }
      },
      onVolatile: { _ in })
    transcribers.append(transcriber)
    var offset = run.samples.startIndex
    while offset < run.samples.endIndex {
      let count = min(16_000, run.samples.endIndex - offset)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: ChannelPipeline.format, frameCapacity: AVAudioFrameCount(count)) else { break }
      buffer.frameLength = AVAudioFrameCount(count)
      for index in 0..<count { buffer.floatChannelData![0][index] = run.samples[offset + index] }
      let start = run.start.addingTimeInterval(Double(offset - run.samples.startIndex) / AudioAlignment.sampleRate)
      transcriber.feed(TimedBuffer(buffer: buffer, start: start))
      offset += count
    }
    transcriber.finish()
    // Summaries for these hours are redone once the new sentences are in.
    let summaries = summaries
    Task {
      try? await Task.sleep(for: .seconds(20 + Double(run.samples.count) / AudioAlignment.sampleRate / 10))
      summaries.invalidate(DateInterval(start: run.start, end: end))
      transcribers.removeAll { $0 === transcriber }
    }
  }
}
