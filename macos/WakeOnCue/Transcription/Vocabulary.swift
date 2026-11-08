import Foundation

/// The user's 常用词: colleagues' names, products and jargon that the recognizers get wrong.
/// They go to Qwen3-ASR as hotwords (and to a transcription service as its prompt), and to the
/// summaries so the model can tell 老罗 from 老郭 in a garbled line.
nonisolated enum Vocabulary {
  /// Hotwords make every decoding step longer; a few dozen words is what they are for.
  static let maxWords = 60

  /// The words in what the user typed: separated by commas, 、, semicolons, spaces or lines,
  /// trimmed, without repeats, at most `maxWords`.
  static func words(from text: String) -> [String] {
    let separators = CharacterSet(charactersIn: ",，、;；|\n\r\t ")
    var seen: Set<String> = []
    var words: [String] = []
    for piece in text.components(separatedBy: separators) {
      let word = piece.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
      words.append(word)
      if words.count == maxWords { break }
    }
    return words
  }

  /// sherpa-onnx takes hotwords as one string split on ASCII commas; nil when there are none.
  static func hotwords(_ words: [String]) -> String? {
    words.isEmpty ? nil : words.joined(separator: ",")
  }

  /// On a short or nearly silent sentence Qwen3-ASR may answer with its hotwords instead of what
  /// was said ("唐总，老罗，贝塔，巡检。"). Such a reply is two or more hotwords and little else.
  static func isEcho(_ text: String, words: [String]) -> Bool {
    guard !words.isEmpty else { return false }
    let pieces = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；。.!！?？ "))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard pieces.count >= 2 else { return false }
    let known = Set(words.map { $0.lowercased() })
    let hits = pieces.filter { known.contains($0.lowercased()) }
    guard hits.count >= 2 else { return false }
    let hitCharacters = hits.reduce(0) { $0 + $1.count }
    let allCharacters = pieces.reduce(0) { $0 + $1.count }
    return Double(hitCharacters) >= Double(allCharacters) * 0.6
  }
}

/// Loudness of the audio handed to a recognizer. The built-in microphone hears colleagues across
/// the desk at around -30 dBFS or lower; the recognizers do better when speech is near full scale.
nonisolated enum AudioLevel {
  /// The loud end of the sentence (99.5th percentile, so one click does not count) is brought to
  /// this level.
  static let target: Float = 0.5
  /// At most +24 dB, so a sentence of room noise is not blown up into something to transcribe.
  static let maxGain: Float = 16

  /// The gain `normalized` applies: never below 1, so loud speech is left alone.
  static func gain(for samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 1 }
    var magnitudes = samples.map { abs($0) }
    let index = min(magnitudes.count - 1, Int(Double(magnitudes.count) * 0.995))
    let peak = quickSelect(&magnitudes, index)
    guard peak > 1e-5 else { return 1 }
    return max(1, min(maxGain, target / peak))
  }

  static func normalized(_ samples: [Float]) -> [Float] {
    let gain = gain(for: samples)
    guard gain > 1.01 else { return samples }
    return samples.map { max(-1, min(1, $0 * gain)) }
  }

  /// The `k`-th smallest value, rearranging `values` (average O(n), unlike sorting a minute of
  /// audio).
  private static func quickSelect(_ values: inout [Float], _ k: Int) -> Float {
    var low = 0
    var high = values.count - 1
    while low < high {
      let pivot = values[(low + high) / 2]
      var i = low
      var j = high
      while i <= j {
        while values[i] < pivot { i += 1 }
        while values[j] > pivot { j -= 1 }
        if i <= j {
          values.swapAt(i, j)
          i += 1
          j -= 1
        }
      }
      if k <= j {
        high = j
      } else if k >= i {
        low = i
      } else {
        return values[k]
      }
    }
    return values[k]
  }
}
