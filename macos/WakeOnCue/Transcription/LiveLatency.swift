import Foundation

/// When live sentences may come out early. Apple speech's `.fastResults` finalizes about three
/// times sooner (median 9.1 s → 3.0 s after the words, on four real five-minute meeting clips)
/// but its own text is worse (CER 58% → 62% against a reference transcript). When a downloaded
/// model or a transcription service re-transcribes every sentence anyway, the stored text
/// changes little (CER 52% → 54%), so the faster results are only used then.
nonisolated enum LiveLatency {
  /// Whether live transcription should favor speed: only when each sentence is transcribed
  /// again by a model, so Apple speech's words are not the ones kept.
  static func fastResults(sentencesAreRetranscribed: Bool) -> Bool {
    sentencesAreRetranscribed
  }
}
