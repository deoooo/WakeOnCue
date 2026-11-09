import Foundation

/// Apple speech cuts speech into short sentences; one to five seconds is too little context for
/// Qwen3-ASR, which then guesses names and words it would get right in a longer stretch. Close
/// sentences are recognized together and the text is split back onto them, so times, speakers
/// and sentence IDs stay as they were.
///
/// On the 11-06 早会 recognizing stretches of up to 20 s gave clearly more fluent text than one
/// sentence at a time ("你做个预案" instead of "你如果能安", "核心就大的流程上" instead of
/// "核心最大的流程上").
nonisolated enum SentenceGroups {
  /// Sentences closer than this belong to the same stretch of speech.
  static let maxGap: TimeInterval = 1.0
  /// A group is at most this long; Qwen3-ASR's output limit and the cost of one mistake grow
  /// with it.
  static let maxSpan: TimeInterval = 20

  /// The group that `id` falls in, from `sentences` of one channel around it, sorted by start.
  /// Groups are cut greedily from the first sentence given, so the caller passes a window that
  /// starts well before `id` (a stretch with no 1-second pause for that long is rare).
  static func group(containing id: Int64, in sentences: [Sentence]) -> [Sentence] {
    var current: [Sentence] = []
    for sentence in sentences {
      if let first = current.first, let last = current.last,
        sentence.start.timeIntervalSince(last.end) >= maxGap || sentence.end.timeIntervalSince(first.start) > maxSpan
      {
        if current.contains(where: { $0.id == id }) { return current }
        current = []
      }
      current.append(sentence)
    }
    if current.contains(where: { $0.id == id }) { return current }
    return sentences.filter { $0.id == id }
  }

  /// Audio kept before the first sentence, so its first word is not clipped.
  static let lead: TimeInterval = 0.25
  /// Audio kept after the last sentence. Apple speech ends a sentence before its last word has
  /// died away: on the 11-06 早会 the 1.7B model kept the last two characters of 16 of 138 groups
  /// with 0.25 s, 79 with 0.8 s and 99 with 1.0 s. Beyond that it mostly picks up the next
  /// speaker, so the tail also stops where the next sentence starts.
  static let tail: TimeInterval = 1.0

  /// The stretch of audio to recognize for `group`: a little before it, and up to `tail` after
  /// it but never into `next` (the following sentence of the channel) or a private or deleted
  /// mark starting after it (`stop`).
  static func audioRange(of group: [Sentence], next: Date?, stop: Date? = nil) -> DateInterval? {
    guard let first = group.first, let last = group.last else { return nil }
    let lastEnd = max(last.end, last.start)
    var end = lastEnd.addingTimeInterval(tail)
    for limit in [next, stop].compactMap({ $0 }) where limit > lastEnd {
      end = min(end, limit)
    }
    let start = first.start.addingTimeInterval(-lead)
    return DateInterval(start: start, end: max(end, lastEnd))
  }

  /// Whether the speech after `group` may still be going on: its last sentence ended so recently
  /// that the next one could still join it.
  static func mayGrow(_ group: [Sentence], now: Date, settle: TimeInterval) -> Bool {
    guard let first = group.first, let last = group.last else { return false }
    return last.end.timeIntervalSince(first.start) < maxSpan && now.timeIntervalSince(last.end) < maxGap + settle
  }
}

/// Splits one recognized text back onto the sentences it was recognized from, by aligning it
/// with their live text character by character and cutting at punctuation near each boundary.
nonisolated enum TextSplitter {
  /// Punctuation within this many characters of a boundary is where the cut goes.
  static let snap = 4

  private static func isContent(_ c: Character) -> Bool {
    !(c.isPunctuation || c.isWhitespace || c.isSymbol)
  }

  private static let leading: Set<Character> = Set("，。、；：,.;:！？!? \n")

  /// One piece per entry of `live`, in order. A piece can be empty when the model heard nothing
  /// for that sentence.
  static func split(_ text: String, along live: [String]) -> [String] {
    guard live.count > 1 else { return [text] }
    let output = Array(text)
    // Content characters of the output, with where they are in it.
    let outputIndex = output.indices.filter { isContent(output[$0]) }
    let o = outputIndex.map { output[$0] }
    var l: [Character] = []
    var boundaries: [Int] = []
    for (index, sentence) in live.enumerated() {
      l += sentence.filter(isContent)
      if index < live.count - 1 { boundaries.append(l.count) }
    }
    let columns = alignedColumns(l, o)
    var cuts: [Int] = []
    for boundary in boundaries {
      let (low, high) = columns[boundary]
      let j = (low + high + 1) / 2
      var cut: Int
      if j <= 0 {
        cut = 0
      } else if j >= o.count {
        cut = output.count
      } else {
        cut = outputIndex[j - 1] + 1
        cut = snapped(cut, in: output, from: outputIndex[max(0, j - snap)], to: outputIndex[min(o.count - 1, j - 1 + snap)])
      }
      cuts.append(max(cut, cuts.last ?? 0))
    }
    var pieces: [String] = []
    var start = 0
    for cut in cuts + [output.count] {
      var piece = String(output[start..<max(start, cut)])
      while let first = piece.first, leading.contains(first) { piece.removeFirst() }
      pieces.append(tidy(piece))
      start = max(start, cut)
    }
    return pieces
  }

  /// A piece ends like a sentence, and a quote cut in half by the split loses its marks.
  private static func tidy(_ piece: String) -> String {
    var characters = Array(piece.trimmingCharacters(in: .whitespacesAndNewlines))
    var open: [Int] = []
    var unmatched: Set<Int> = []
    for (index, character) in characters.enumerated() {
      if character == "“" {
        open.append(index)
      } else if character == "”" {
        if open.popLast() == nil { unmatched.insert(index) }
      }
    }
    unmatched.formUnion(open)
    characters = characters.enumerated().filter { !unmatched.contains($0.offset) }.map(\.element)
    var text = String(characters)
    if let last = text.last, "，、；：,;:".contains(last) {
      text.removeLast()
      text.append("。")
    }
    return text
  }

  /// The cut moved to just after the nearest run of punctuation between `from` and `to`, if any.
  private static func snapped(_ cut: Int, in output: [Character], from: Int, to: Int) -> Int {
    var best: Int?
    var index = from
    while index <= to, index < output.count {
      if !isContent(output[index]) {
        var end = index
        while end + 1 < output.count, !isContent(output[end + 1]) { end += 1 }
        let candidate = end + 1
        if best == nil || abs(candidate - cut) < abs(best! - cut) { best = candidate }
        index = end + 1
      } else {
        index += 1
      }
    }
    return best ?? cut
  }

  /// For each prefix length `i` of `a`, the range of prefix lengths of `b` it is aligned with on
  /// a minimum edit path.
  private static func alignedColumns(_ a: [Character], _ b: [Character]) -> [(Int, Int)] {
    let n = a.count
    let m = b.count
    var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { cost[i][0] = i }
    for j in 0...m { cost[0][j] = j }
    if n > 0, m > 0 {
      for i in 1...n {
        for j in 1...m {
          let substitute = cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
          cost[i][j] = min(substitute, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
        }
      }
    }
    var columns = Array(repeating: (Int.max, Int.min), count: n + 1)
    var i = n
    var j = m
    while true {
      columns[i] = (min(columns[i].0, j), max(columns[i].1, j))
      if i == 0 && j == 0 { break }
      if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
        i -= 1
        j -= 1
      } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
        i -= 1
      } else {
        j -= 1
      }
    }
    return columns
  }
}
