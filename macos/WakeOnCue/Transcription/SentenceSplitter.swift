import Foundation

/// Splits Apple speech's final results into sentences. Live results carry little punctuation, so
/// splitting at "。？！" alone gave 10–17 second lines holding several people's turns; a pause
/// between words, or a comma once a sentence is long, ends a sentence too.
nonisolated enum SentenceSplitter {
  /// A run of the result: its text and, when known, its audio time in seconds.
  struct Piece: Equatable {
    var text: String
    var start: Double?
    var end: Double?
  }

  struct Span: Equatable {
    var text: String
    var start: Double
    var end: Double
  }

  static let enders: Set<Character> = ["。", "？", "！", "?", "!", "；", ";"]
  private static let commas: Set<Character> = ["，", ",", "、"]
  /// Silence between two words that ends a sentence.
  static let pause: Double = 0.8
  /// About how long a Chinese character takes to say; a word lasting much longer held a pause.
  static let secondsPerCharacter: Double = 0.35
  /// From this long on, a comma ends the sentence too.
  static let longSentence: Double = 8
  /// A pause after fewer characters than this ("嗯", "对对") does not split; the reply stays
  /// with what follows.
  static let minimumCharacters = 4

  static func split(_ pieces: [Piece]) -> [Span] {
    var spans: [Span] = []
    var current = ""
    var start: Double?
    var end: Double?

    func spoken(_ text: String) -> Int {
      text.filter { !$0.isPunctuation && !$0.isWhitespace }.count
    }

    func flush() {
      let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if spoken(trimmed) > 0, let start {
        spans.append(Span(text: trimmed, start: start, end: max(start, end ?? start)))
      }
      current = ""
      start = nil
      end = nil
    }

    for piece in pieces {
      // Apple speech's word times touch each other: a silence shows up as a gap, or as a word
      // that lasts far longer than it takes to say. Either way the words start after it.
      var wordStart = piece.start
      if let pieceStart = piece.start, let pieceEnd = piece.end {
        let words = max(spoken(piece.text), 1)
        let said = min(pieceEnd - pieceStart, secondsPerCharacter * Double(words))
        let silence = max(pieceStart - (end ?? pieceStart), pieceEnd - pieceStart - said)
        if silence >= pause {
          wordStart = pieceEnd - said
          if spoken(current) >= minimumCharacters { flush() }
        }
      }
      for character in piece.text {
        if !character.isPunctuation, !character.isWhitespace {
          if start == nil { start = wordStart }
          if let pieceEnd = piece.end { end = pieceEnd }
        }
        current.append(character)
        let long = (end ?? 0) - (start ?? .infinity) >= longSentence
        if enders.contains(character) || (long && commas.contains(character)) { flush() }
      }
    }
    flush()
    return spans
  }
}
