import Foundation
import WakeOnCueCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// One recording's local text, as read for answering questions.
struct RecordingQuestionSource: Sendable {
  let recording: RecordingRecord
  let transcript: [RealtimeTranscriptEvent]
  let summary: RecordingSummary?
}

/// A transcript segment an answer relies on; tapping it opens the recording at `startTime`.
struct RecordingCitation: Identifiable, Equatable, Sendable {
  let recording: RecordingRecord
  let segment: RealtimeTranscriptEvent
  /// The user's title, else the on-device summary's title.
  let recordingTitle: String?
  let score: Double
  /// Resolved on the main actor from aliases and saved voices; never leaves the iPhone.
  var speakerName: String?

  var id: String { "\(recording.id)/\(segment.segmentID)" }
  var startTime: TimeInterval { TimeInterval(segment.startMilliseconds) / 1_000 }

  var timestamp: String { RecordingTranscriptExporter.playbackTimestamp(startTime) }
}

struct RecordingAnswer: Equatable, Sendable {
  enum Notice: Equatable, Sendable {
    /// No transcript text matched the question.
    case nothingFound
    /// Passages matched, but they do not answer the question.
    case notInRecordings
    /// Apple Intelligence is off or unsupported; only passages are shown.
    case intelligenceUnavailable
    case failed(String)
  }

  var text: String?
  var notice: Notice?
  var sources: [RecordingCitation]
}

/// Keyword retrieval that works for languages with and without spaces, so it needs no
/// embedding model: words for alphabetic scripts, overlapping character pairs for CJK.
enum RecordingQuestionRetriever {
  static let defaultLimit = 8

  private static let stopWords: Set<String> = [
    "a", "an", "and", "are", "about", "at", "be", "by", "did", "do", "does", "for", "from",
    "had", "has", "have", "how", "i", "in", "is", "it", "me", "my", "of", "on", "or", "our",
    "say", "said", "that", "the", "their", "them", "they", "this", "to", "was", "we", "were",
    "what", "when", "where", "which", "who", "why", "will", "with", "you", "your",
  ]
  private static let cjkStopGrams: Set<String> = [
    "我们", "你们", "他们", "什么", "关于", "一下", "这个", "那个", "怎么", "是不", "不是",
    "有没", "没有", "了什", "的是", "是什", "吗", "呢", "了", "的", "是", "吧", "啊",
  ]

  static func terms(_ text: String) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    var word = ""
    var run: [Character] = []

    func add(_ term: String) {
      if seen.insert(term).inserted { result.append(term) }
    }
    func flushWord() {
      if !word.isEmpty, !stopWords.contains(word), word.count > 1 || word.allSatisfy(\.isNumber) {
        add(word)
      }
      word = ""
    }
    func flushRun() {
      if run.count == 1 {
        let single = String(run)
        if !cjkStopGrams.contains(single) { add(single) }
      } else if run.count > 1 {
        for index in 0..<(run.count - 1) {
          let gram = String(run[index...index + 1])
          if !cjkStopGrams.contains(gram) { add(gram) }
        }
      }
      run = []
    }

    for character in text.lowercased() {
      if isCJK(character) {
        flushWord()
        run.append(character)
      } else if character.isLetter || character.isNumber {
        flushRun()
        word.append(character)
      } else {
        flushWord()
        flushRun()
      }
    }
    flushWord()
    flushRun()
    return result
  }

  static func retrieve(
    question: String,
    sources: [RecordingQuestionSource],
    limit: Int = defaultLimit
  ) -> [RecordingCitation] {
    let terms = terms(question)
    let phrase = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !terms.isEmpty || !phrase.isEmpty else { return [] }

    var hits: [RecordingCitation] = []
    for source in sources {
      let title = source.recording.title ?? source.summary?.title
      let titleText = title?.lowercased() ?? ""
      let titleBonus = terms.contains { titleText.contains($0) } ? 0.5 : 0
      for segment in latestRevisions(source.transcript) {
        let text = segment.text.lowercased()
        let matched = terms.filter { text.contains($0) }
        let containsPhrase = !phrase.isEmpty && text.contains(phrase)
        guard !matched.isEmpty || containsPhrase else { continue }
        let coverage = terms.isEmpty ? 1 : Double(matched.count) / Double(terms.count)
        let occurrences = matched.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
        let score = coverage * 2 + Double(occurrences) * 0.1 + titleBonus + (containsPhrase ? 2 : 0)
        hits.append(
          RecordingCitation(
            recording: source.recording, segment: segment, recordingTitle: title, score: score))
      }
    }
    return Array(
      hits.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.recording.startedAt != $1.recording.startedAt {
          return $0.recording.startedAt > $1.recording.startedAt
        }
        return $0.segment.startMilliseconds < $1.segment.startMilliseconds
      }
      .prefix(max(1, limit)))
  }

  private static func latestRevisions(_ transcript: [RealtimeTranscriptEvent])
    -> [RealtimeTranscriptEvent]
  {
    var latest: [String: RealtimeTranscriptEvent] = [:]
    for segment in transcript where !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
      if let current = latest[segment.segmentID], current.revision > segment.revision { continue }
      latest[segment.segmentID] = segment
    }
    return latest.values.sorted { $0.startMilliseconds < $1.startMilliseconds }
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
        true
      default:
        false
      }
    }
  }
}

enum RecordingQuestionAnswering {
  /// Generated-answer pass, used only once retrieval found passages. Without Apple
  /// Intelligence the matching passages are returned with no generated text.
  static func answer(
    question: String,
    citations: [RecordingCitation],
    language: AppLanguage
  ) async -> RecordingAnswer {
    guard !citations.isEmpty else {
      return RecordingAnswer(text: nil, notice: .nothingFound, sources: [])
    }
    guard OnDeviceIntelligence.canSummarize else {
      return RecordingAnswer(text: nil, notice: .intelligenceUnavailable, sources: citations)
    }
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        do {
          return try await FoundationModelAnswerer(language: language).answer(
            question: question, citations: citations)
        } catch {
          return RecordingAnswer(
            text: nil, notice: .failed(error.localizedDescription), sources: citations)
        }
      }
    #endif
    return RecordingAnswer(text: nil, notice: .intelligenceUnavailable, sources: citations)
  }

  /// Numbered excerpts trimmed to fit the small on-device context window.
  static func excerpts(
    for citations: [RecordingCitation],
    maxCharacters: Int = 3_000,
    perExcerpt: Int = 360
  ) -> [String] {
    var result: [String] = []
    var used = 0
    for (index, citation) in citations.enumerated() {
      let text = String(citation.segment.text.prefix(perExcerpt))
      let speaker = citation.speakerName.map { "\($0): " } ?? ""
      let title = citation.recordingTitle.map { " \"\($0)\"" } ?? ""
      let line = "[\(index + 1)] Recording\(title) at \(citation.timestamp) — \(speaker)\(text)"
      if used + line.count > maxCharacters, !result.isEmpty { break }
      used += line.count
      result.append(line)
    }
    return result
  }
}

#if canImport(FoundationModels)
  @available(iOS 26.0, *)
  @Generable
  struct RecordingAnswerDraft {
    @Guide(description: "true only if the numbered excerpts contain the answer")
    var answerable: Bool
    @Guide(description: "One to four sentences that answer the question using only the excerpts; empty if not answerable")
    var answer: String
    @Guide(description: "Numbers of the excerpts the answer relies on")
    var sources: [Int]
  }

  @available(iOS 26.0, *)
  struct FoundationModelAnswerer {
    let language: AppLanguage

    func answer(question: String, citations: [RecordingCitation]) async throws -> RecordingAnswer {
      var budget = 3_000
      while true {
        let excerpts = RecordingQuestionAnswering.excerpts(for: citations, maxCharacters: budget)
        do {
          let session = LanguageModelSession(instructions: instructions)
          let draft = try await session.respond(
            to: "Excerpts:\n\(excerpts.joined(separator: "\n"))\n\nQuestion: \(question)",
            generating: RecordingAnswerDraft.self
          ).content
          let answer = draft.answer.trimmingCharacters(in: .whitespacesAndNewlines)
          guard draft.answerable, !answer.isEmpty else {
            return RecordingAnswer(text: nil, notice: .notInRecordings, sources: citations)
          }
          let cited = draft.sources.compactMap { number in
            (1...excerpts.count).contains(number) ? citations[number - 1] : nil
          }
          let unique = cited.reduce(into: [RecordingCitation]()) { result, citation in
            if !result.contains(where: { $0.id == citation.id }) { result.append(citation) }
          }
          return RecordingAnswer(
            text: answer, notice: nil,
            sources: unique.isEmpty ? Array(citations.prefix(excerpts.count)) : unique)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where budget > 600 {
          budget /= 2
        }
      }
    }

    private var instructions: String {
      let output = language == .simplifiedChinese ? "Simplified Chinese" : "the language of the question"
      return """
        You answer questions about the user's own recorded conversations. \
        Use only the numbered excerpts you are given; never add facts, names, dates or \
        numbers that are not in them. If the excerpts do not answer the question, set \
        answerable to false. Write in \(output).
        """
    }
  }
#endif
