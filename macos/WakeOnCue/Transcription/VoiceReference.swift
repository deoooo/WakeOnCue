import Foundation

/// How the user's own voice is known, kept apart from the model and the keychain so the rules can
/// be tested.
///
/// Measured on two days of this Mac's built-in microphone (2544 sentences, 2026-11-03/04): two
/// sentences of the same voice score about 0.7, different voices about 0.2 (90th percentile 0.38).
/// A reference made from 20 of one voice's own sentences, at 0.5, found 97–99% of that voice's
/// other sentences and took 1–7% of everyone else's. Fitting the threshold to each day's spread
/// (Otsu) did worse, so it stays fixed.
nonisolated enum VoiceReference {
  /// Cosine similarity to the user's reference at which a sentence counts as "我".
  static let meThreshold: Float = 0.5
  /// Adapting the enrollment: the sentences closest to it (at most `adaptNeighbours`, none below
  /// `adaptFloor`) are taken as the user's and averaged in, three times over. A reading into the
  /// microphone sounds different from the user across the room; simulated on the measured data
  /// with an enrollment only 0.57–0.65 similar to the voice's own sentences, this raised the
  /// share of that voice found from 1–39% to 66–94%, while 1–14% of others counted as it.
  static let adaptNeighbours = 30
  static let adaptFloor: Float = 0.4
  static let adaptMinimum = 10
  static let adaptRounds = 3
  /// Sentences shorter than this give a noisy embedding: not used to learn or adapt.
  static let minimumSeconds: TimeInterval = 2

  /// The enrolled voice moved toward how this Mac's microphone hears the user, or nil when too
  /// few recent sentences are close to it.
  static func adapted(_ enrolled: [Float], with candidates: [[Float]]) -> [Float]? {
    var reference = enrolled
    var adapted: [Float]?
    for _ in 0..<adaptRounds {
      let mine = candidates
        .map { ($0, similarity($0, reference)) }
        .filter { $0.1 >= adaptFloor }
        .sorted { $0.1 > $1.1 }
        .prefix(adaptNeighbours)
        .map(\.0)
      guard mine.count >= adaptMinimum, let heard = mean(mine) else { break }
      reference = normalized(zip(enrolled, heard).map { $0 + $1 })
      adapted = reference
    }
    return adapted
  }

  static func isMe(_ embedding: [Float], reference: [Float]) -> Bool {
    similarity(embedding, reference) >= meThreshold
  }

  static func normalized(_ vector: [Float]) -> [Float] {
    let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return length > 0 ? vector.map { $0 / length } : vector
  }

  static func similarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
  }

  static func mean(_ vectors: [[Float]]) -> [Float]? {
    guard let first = vectors.first else { return nil }
    var sum = [Float](repeating: 0, count: first.count)
    for vector in vectors where vector.count == first.count {
      for index in sum.indices { sum[index] += vector[index] }
    }
    return normalized(sum)
  }

}
