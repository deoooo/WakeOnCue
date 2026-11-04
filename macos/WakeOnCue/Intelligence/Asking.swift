import Foundation
import Observation

/// "提问": answers questions about the recordings with citations. The question is turned into
/// search words, matching sentences and their neighbours are collected (never from private or
/// deleted time), and the summary engine answers from them only.
@Observable
final class Asking {
  struct Exchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: [CitedLine] = []
    var error: String?
    var working = true
    /// The sentences the answer may cite, for showing citations.
    var sources: [Int64: Sentence] = [:]
  }

  private(set) var exchanges: [Exchange] = []

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let summaries: Summaries

  init(store: Store, summaries: Summaries) {
    self.store = store
    self.summaries = summaries
  }

  var isWorking: Bool { exchanges.last?.working == true }

  func clear() { exchanges = [] }

  func ask(_ question: String) {
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isWorking else { return }
    exchanges.append(Exchange(question: question))
    let index = exchanges.count - 1
    Task {
      do {
        guard let engine = summaries.engine else {
          throw AskError.unavailable(summaries.unavailableReason ?? "没有可用的 AI 服务")
        }
        let (answer, sources) = try await answer(question, engine: engine)
        exchanges[index].answer = answer
        exchanges[index].sources = sources
      } catch {
        exchanges[index].error = error.localizedDescription
      }
      exchanges[index].working = false
    }
  }

  private enum AskError: LocalizedError {
    case unavailable(String)
    case nothingFound

    var errorDescription: String? {
      switch self {
      case .unavailable(let reason): "\(reason)，没法回答。可以在设置 › AI 服务里配置网关。"
      case .nothingFound: "在录音里没找到相关的内容。标为私人或已删除的时段不会被搜索。"
      }
    }
  }

  private func answer(_ question: String, engine: any SummaryEngine) async throws -> ([CitedLine], [Int64: Sentence]) {
    let today = Calendar.current.startOfDay(for: .now)
    let plan = try await engine.plan("""
      今天是 \(TimeText.day(.now))。用户想在自己的录音转录里找答案，问题是：「\(question)」
      给出在转录里搜索用的词，以及要往前查几天。
      """)
    let since = plan.days > 0 ? Calendar.current.date(byAdding: .day, value: 1 - plan.days, to: today)! : .distantPast
    let hidden = store.marks()
    let visible = { (s: Sentence) in s.start >= since && !hidden.contains { $0.covers(s.start) } }

    // Rank sentences by how many search words they contain, then add the sentences around each.
    var scores: [Int64: (Sentence, Int)] = [:]
    for keyword in plan.keywords.map({ $0.trimmingCharacters(in: .whitespaces) }) where keyword.count >= 1 {
      for hit in store.search(keyword, limit: 200) where visible(hit) {
        scores[hit.id, default: (hit, 0)].1 += 1
      }
    }
    let top = scores.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.start > $1.0.start }.prefix(25).map(\.0)
    var picked: [Int64: Sentence] = [:]
    for hit in top {
      for sentence in store.sentences(in: DateInterval(start: hit.start.addingTimeInterval(-40), end: hit.start.addingTimeInterval(40))) where visible(sentence) {
        picked[sentence.id] = sentence
      }
    }
    // Questions like "今天聊了什么" have no good search words; fall back to the hour summaries' key sentences.
    if picked.isEmpty {
      let interval = DateInterval(start: plan.days > 0 ? since : today.addingTimeInterval(-6 * 86_400), end: .now)
      let keys = store.hourSummaries(in: interval).values.flatMap(\.keySentenceIDs)
      for sentence in store.sentences(ids: keys) where visible(sentence) { picked[sentence.id] = sentence }
    }
    guard !picked.isEmpty else { throw AskError.nothingFound }

    var sources = picked.values.sorted { $0.start < $1.start }
    var size = 0
    sources = sources.filter { sentence in
      size += sentence.text.count + 20
      return size <= engine.partCharacters
    }
    let lines = sources.enumerated().map { index, s in
      "[\(index + 1)] \(TimeText.relativeDay(s.start)) \(TimeText.clock(s.start)) \(s.speaker.label)：\(s.text)"
    }.joined(separator: "\n")
    let paragraphs = try await engine.answer("""
      用户的问题：「\(question)」
      下面是从用户自己的录音转录里找到的相关原话，每句前面有编号。只根据这些原话回答，简短直接；\
      原话里没有答案就直说没找到。每段注明依据的原话编号。

      \(lines)
      """)
    let answer = paragraphs.map { paragraph in
      CitedLine(text: paragraph.text, cites: paragraph.sources.compactMap { sources.indices.contains($0 - 1) ? sources[$0 - 1].id : nil })
    }
    return (answer, Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
  }
}
