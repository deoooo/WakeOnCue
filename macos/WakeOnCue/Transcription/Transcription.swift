import Foundation
import Observation

/// Turns recognized sentences into stored ones and keeps the live (still changing) lines.
@Observable
final class Transcription {
  enum Status: Equatable {
    case preparing
    case downloading(Double)
    case ready
    case failed(String)
  }

  /// Whether Apple speech is ready, for first run, settings and the banner.
  private(set) var status: Status = .preparing
  /// A setup problem, e.g. the Mandarin model could not be downloaded.
  var issue: String? {
    if case .failed(let reason) = status { return reason }
    return nil
  }
  private(set) var live: [AudioChannel: VolatileText] = [:]
  /// The most recent finished line, for the menu bar.
  private(set) var lastSentence: Sentence?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let recorder: Recorder
  @ObservationIgnored private var transcribers: [AudioChannel: LiveTranscriber] = [:]
  /// Loudness of recent sentences said by the user, to spot quieter, farther voices.
  @ObservationIgnored private var myLoudness: [Float] = []
  @ObservationIgnored private var starting = false
  /// Called after every stored sentence, so summaries can follow along.
  @ObservationIgnored var onSentence: ((Sentence) -> Void)?

  init(store: Store, recorder: Recorder) {
    self.store = store
    self.recorder = recorder
  }

  /// Gets the Mandarin model ready and connects to the recorder. A failure (e.g. offline on
  /// first run, while the model downloads) is retried every minute.
  func start() async {
    guard transcribers.isEmpty, !starting else { return }
    starting = true
    defer { starting = false }
    status = .preparing
    if let reason = await LiveTranscriber.prepare(onDownload: { [weak self] in self?.status = .downloading($0) }) {
      status = .failed(reason)
      Store.logger.error("Transcription unavailable: \(reason, privacy: .public)")
      Task {
        try? await Task.sleep(for: .seconds(60))
        await start()
      }
      return
    }
    status = .ready
    let channel = AudioChannel.microphone
    let transcriber = LiveTranscriber(
      channel: channel,
      onSentence: { [weak self] sentence in Task { @MainActor in self?.save(sentence) } },
      onVolatile: { [weak self] text in Task { @MainActor in self?.live[channel] = text } })
    transcribers[channel] = transcriber
    transcriber.setFastResults(fastResults)
    let transcribers = transcribers
    recorder.audioOut.connect { channel, buffer in
      transcribers[channel]?.feed(buffer)
    }
  }

  /// Whether a downloaded model or transcription service re-transcribes every sentence; then
  /// live results come out sooner, since their words are replaced anyway.
  @ObservationIgnored private var fastResults = false

  func setSentencesRetranscribed(_ on: Bool) {
    fastResults = LiveLatency.fastResults(sentencesAreRetranscribed: on)
    for transcriber in transcribers.values { transcriber.setFastResults(fastResults) }
  }

  /// Finalizes what has been heard so far, e.g. when recording pauses.
  func flush() {
    for transcriber in transcribers.values { transcriber.finish() }
  }

  private func save(_ recognized: RecognizedSentence) {
    // A lone "M" or "Thank you" heard in a noise is not worth a line.
    if TranscriptFilter.isNoise(recognized.text) { return }
    switch recognized.channel {
    case .remote, .meeting:
      // Forwarded audio is transcribed by the merger; old meeting recordings are read-only.
      return
    case .microphone:
      let speaker = speaker(for: recognized)
      let id = store.insertSentence(
        start: recognized.start, end: recognized.end, channel: .microphone, speaker: speaker,
        source: "Mac 麦克风", text: recognized.text)
      finish(Sentence(
        id: id, start: recognized.start, end: recognized.end, channel: .microphone, speaker: speaker,
        source: "Mac 麦克风", text: recognized.text))
    }
  }

  private func finish(_ sentence: Sentence) {
    lastSentence = sentence
    onSentence?(sentence)
  }

  /// The simplest useful split: a voice much quieter than the user's usual level is someone
  /// else in the room. Until enough of the user's speech is known, everything is the user.
  private func speaker(for sentence: RecognizedSentence) -> Speaker {
    guard let loudness = recorder.micPipeline.loudness(from: sentence.start, to: sentence.end) else { return .me }
    let sorted = myLoudness.sorted()
    let typical = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    if myLoudness.count >= 10, loudness < typical * 0.35 { return .other }
    myLoudness.append(loudness)
    if myLoudness.count > 200 { myLoudness.removeFirst() }
    return .me
  }
}

import SwiftUI

/// "✓ 已就绪", "正在下载中文语音模型 42%", or why it failed.
struct SpeechStatusText: View {
  let status: Transcription.Status

  var body: some View {
    switch status {
    case .preparing:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在检查中文语音模型…")
      }
      .foregroundStyle(.secondary)
    case .downloading(let fraction):
      HStack(spacing: 6) {
        ProgressView(value: fraction).frame(width: 80)
        Text("正在下载中文语音模型 \(Int(fraction * 100))%")
      }
      .foregroundStyle(.secondary)
    case .ready:
      Text("✓ 已就绪").foregroundStyle(.green)
    case .failed(let reason):
      Text("\(reason)，每分钟自动重试").foregroundStyle(Color.recording)
    }
  }
}
