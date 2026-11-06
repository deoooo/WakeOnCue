import Foundation

/// Groups unnamed voices of one day into 说话人 2, 3… Pure state, so the rules can be tested
/// without a speaker model or a library.
nonisolated struct SpeakerClustering {
  struct Cluster: Equatable, Sendable {
    var day: Date
    var label: String
    var embedding: [Float]
    var count: Int
  }

  /// A small cluster merged into `to`; a nil target means it became just "他人".
  struct Merge: Equatable, Sendable {
    var from: String
    var to: String?
  }

  /// Sentences shorter than this do not make a new speaker: their voice is too noisy to group.
  static let minimumSeconds: TimeInterval = 2
  /// Same voice sentences score about 0.69 in the far-field recordings; 0.5 keeps them together
  /// without joining different people.
  var threshold: Float = 0.5
  /// A 1–2 sentence cluster is merged when it is at least this close to a bigger speaker; it is
  /// a little lower than `threshold` because those clusters were too short to judge on their own.
  var mergeThreshold: Float = 0.4

  private(set) var clusters: [Cluster] = []

  var days: [Date] { Set(clusters.map(\.day)).sorted() }

  /// Carries a name the user gave to the in-memory cluster, so later sentences of the same day
  /// use the name instead of creating a new 说话人 N.
  mutating func rename(_ old: String, to new: String, day: Date) {
    for index in clusters.indices where clusters[index].day == day && clusters[index].label == old {
      clusters[index].label = new
    }
  }

  /// The day's unnamed speaker this voice belongs to, or a new 说话人 N. Short sentences get no
  /// speaker at all (nil = "他人").
  mutating func assign(embedding: [Float], day: Date, seconds: TimeInterval) -> String? {
    clusters.removeAll { $0.day < day.addingTimeInterval(-86_400) }
    guard seconds >= Self.minimumSeconds else { return nil }
    let today = clusters.indices.filter { clusters[$0].day == day }
    if let best = today.max(by: {
      VoiceReference.similarity(embedding, clusters[$0].embedding) < VoiceReference.similarity(embedding, clusters[$1].embedding)
    }), VoiceReference.similarity(embedding, clusters[best].embedding) >= threshold {
      let count = clusters[best].count
      clusters[best].embedding = VoiceReference.normalized(
        zip(clusters[best].embedding, embedding).map { ($0.0 * Float(count) + $0.1) / Float(count + 1) })
      clusters[best].count += 1
      return clusters[best].label
    }
    let numbers = today.compactMap { Int(clusters[$0].label.dropFirst("说话人 ".count)) }
    let label = "说话人 \((numbers.max() ?? 1) + 1)"
    clusters.append(Cluster(day: day, label: label, embedding: embedding, count: 1))
    return label
  }

  /// A day's unnamed clusters with only 1–2 sentences are too small to be a real speaker. Each is
  /// merged into the most similar bigger cluster of the same day when similarity is at least
  /// `mergeThreshold`; otherwise its sentences become just "他人". Clusters the user has named
  /// are never touched.
  mutating func consolidate(day: Date) -> [Merge] {
    let today = clusters.indices.filter { clusters[$0].day == day }
    let small = today.filter { clusters[$0].count <= 2 && clusters[$0].label.hasPrefix("说话人 ") }
    guard !small.isEmpty else { return [] }
    var merges: [Merge] = []
    var removed = Set<Int>()
    for index in small {
      let candidates = today.filter { $0 != index && clusters[$0].count > 2 }
      if let best = candidates.max(by: {
        VoiceReference.similarity(clusters[index].embedding, clusters[$0].embedding)
          < VoiceReference.similarity(clusters[index].embedding, clusters[$1].embedding)
      }), VoiceReference.similarity(clusters[index].embedding, clusters[best].embedding) >= mergeThreshold {
        let count = clusters[best].count
        let added = clusters[index].count
        clusters[best].embedding = VoiceReference.normalized(
          zip(clusters[best].embedding, clusters[index].embedding).map {
            ($0.0 * Float(count) + $0.1 * Float(added)) / Float(count + added)
          })
        clusters[best].count += added
        merges.append(Merge(from: clusters[index].label, to: clusters[best].label))
      } else {
        merges.append(Merge(from: clusters[index].label, to: nil))
      }
      removed.insert(index)
    }
    clusters = clusters.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    return merges
  }
}
