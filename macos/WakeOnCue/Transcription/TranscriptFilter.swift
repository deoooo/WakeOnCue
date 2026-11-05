import Foundation

/// Rules that keep recognition noise out of the transcript, measured on real recordings:
/// Apple speech hears a lone "M", "O" or "Thank you" in a short noise, and Qwen3-ASR sometimes
/// leaks its end token followed by made-up text ("<|endoftext|>Human Rights Watch…"), answers
/// "language Chinese" or "�" for a sentence it could not read, or spells letters apart ("A P P").
nonisolated enum TranscriptFilter {
  /// What models say on silence or a cough, compared without case and punctuation.
  private static let hallucinations: Set<String> = [
    "you", "thankyou", "thakyou", "thanks", "thanksforwatching", "bye", "byebye", "oh", "mm", "hmm", "uh", "um", "wow",
  ]

  /// Short English that is really said on its own.
  private static let shortWords: Set<String> = ["ok", "ai", "no", "hi", "go"]

  static func hasChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
  }

  /// A live sentence that is noise, not speech: no Chinese and one or two letters ("M", "Wa",
  /// "MB"), or one of the phrases models make up on silence. Numbers and "OK" are kept.
  static func isNoise(_ text: String) -> Bool {
    let compact = text.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }
    if compact.isEmpty { return true }
    if hasChinese(compact) || compact.contains(where: \.isNumber) { return false }
    let word = compact.lowercased()
    if hallucinations.contains(word) { return true }
    return compact.count <= 2 && !shortWords.contains(word)
  }

  /// The words of a model's reply: no language tag, no special tokens or what follows them,
  /// no replacement characters, and spelled-out letters joined ("A P P" → "APP").
  static func cleanModelOutput(_ text: String) -> String {
    var result = text
    if let range = result.range(of: "<asr_text>") { result = String(result[range.upperBound...]) }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("language ") {
      // "language Chinese" alone means nothing was heard; otherwise the words follow the tag.
      let rest = trimmed.dropFirst("language ".count)
      if let split = rest.firstIndex(where: { $0 == " " || $0 == "\n" }) {
        result = String(rest[split...])
      } else {
        result = ""
      }
    }
    // Everything after a special token is the decoder running on without audio.
    if let range = result.range(of: "<|") { result = String(result[..<range.lowerBound]) }
    result = result.replacingOccurrences(of: "\u{FFFD}", with: "")
    return joinSpacedLetters(result).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// "A P P" → "APP", "S M T P的" → "SMTP的"; words like "Hello world" stay apart.
  static func joinSpacedLetters(_ text: String) -> String {
    let characters = Array(text)
    var output = ""
    var index = 0
    func isLetter(_ i: Int) -> Bool { characters.indices.contains(i) && characters[i].isASCII && characters[i].isLetter }
    func isSingle(_ i: Int) -> Bool { isLetter(i) && !isLetter(i - 1) && !isLetter(i + 1) }
    while index < characters.count {
      // A run of single letters separated by one space each: "A P P".
      if isSingle(index), characters.indices.contains(index + 2), characters[index + 1] == " ", isSingle(index + 2) {
        var run = String(characters[index])
        var next = index
        while characters.indices.contains(next + 2), characters[next + 1] == " ", isSingle(next + 2) {
          run.append(characters[next + 2])
          next += 2
        }
        output += run
        index = next + 1
        continue
      }
      output.append(characters[index])
      index += 1
    }
    return output
  }

  /// Whether a re-transcription should replace the live text. A reply with no words, or one
  /// with no Chinese where Apple speech heard Chinese (Qwen3-ASR's "Hello, world." or
  /// Vietnamese on a mumble), keeps the live text.
  static func shouldReplace(live: String, with refined: String) -> Bool {
    guard !refined.isEmpty, !isNoise(refined) || isNoise(live) else { return false }
    if hasChinese(live), !hasChinese(refined) { return false }
    return true
  }
}
