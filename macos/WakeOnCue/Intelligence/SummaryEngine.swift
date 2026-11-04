import Foundation
import FoundationModels

/// What a summary engine returns. Numbers refer to the numbered transcript lines in the prompt.
nonisolated struct HourResult: Sendable {
  var summary: String
  var keySentences: [Int]
}

nonisolated struct CitedResult: Sendable {
  var text: String
  var sources: [Int]
}

nonisolated struct DayResult: Sendable {
  var headline: CitedResult
  var details: [CitedResult]
}

/// Where summaries are generated: Apple Intelligence on this Mac, or an OpenAI-compatible gateway
/// the user configured. Prompts are shared; each engine only differs in how it gets structure back.
protocol SummaryEngine: Sendable {
  /// Shown next to every summary, e.g. "本机 Apple 智能" or "网关 gpt-4o-mini".
  var name: String { get }
  /// Where transcripts go, or nil when they stay on this Mac.
  var destination: String? { get }
  /// Characters of transcript per request.
  var partCharacters: Int { get }

  func hour(_ prompt: String) async throws -> HourResult
  func text(_ prompt: String) async throws -> String
  func day(_ prompt: String) async throws -> DayResult
  func points(_ prompt: String) async throws -> [CitedResult]
}

nonisolated enum SummaryPrompts {
  static let instructions = """
    你在为录音的主人整理他们自己一天里的对话。只根据转录内容写，不编造人名、日期或决定。\
    说话人只有三种：「我」是录音的主人，「会议对方」是会议软件里的其他人，「他人」是身边的其他人。\
    用简体中文，句子简短、具体。
    """
}

/// Apple Intelligence through Foundation Models. Structured output comes from @Generable types.
nonisolated struct AppleIntelligenceEngine: SummaryEngine {
  var name: String { "本机 Apple 智能" }
  var destination: String? { nil }
  /// The on-device context window is small; leave room for instructions and output.
  var partCharacters: Int { 1_800 }

  static var unavailableReason: String? {
    switch SystemLanguageModel.default.availability {
    case .available: nil
    case .unavailable(.deviceNotEligible): "这台 Mac 不支持 Apple 智能"
    case .unavailable(.appleIntelligenceNotEnabled): "Apple 智能没有打开"
    case .unavailable(.modelNotReady): "Apple 智能还在准备中"
    case .unavailable: "Apple 智能现在不可用"
    }
  }

  private func session() -> LanguageModelSession {
    LanguageModelSession(instructions: SummaryPrompts.instructions)
  }

  func hour(_ prompt: String) async throws -> HourResult {
    let draft = try await session().respond(to: prompt, generating: HourDraft.self).content
    return HourResult(summary: draft.summary, keySentences: draft.keySentences)
  }

  func text(_ prompt: String) async throws -> String {
    try await session().respond(to: prompt).content
  }

  func day(_ prompt: String) async throws -> DayResult {
    let draft = try await session().respond(to: prompt, generating: DayDraft.self).content
    return DayResult(headline: draft.headline.result, details: draft.details.map(\.result))
  }

  func points(_ prompt: String) async throws -> [CitedResult] {
    try await session().respond(to: prompt, generating: PointsDraft.self).content.points.map(\.result)
  }
}

@Generable
struct HourDraft {
  @Guide(description: "这一小时谈了什么，一到两句话")
  var summary: String
  @Guide(description: "最能代表这一小时内容的二到五句原话的编号", .count(0...5))
  var keySentences: [Int]
}

@Generable
struct CitedDraft {
  @Guide(description: "一句话")
  var text: String
  @Guide(description: "这句话依据的原话编号，一到三个", .count(1...3))
  var sources: [Int]

  nonisolated var result: CitedResult { CitedResult(text: text, sources: sources) }
}

@Generable
struct DayDraft {
  @Guide(description: "用一句话说出今天最重要的结果")
  var headline: CitedDraft
  @Guide(description: "当天的要点，每条一句话", .count(1...6))
  var details: [CitedDraft]
}

@Generable
struct PointsDraft {
  @Guide(description: "会议要点，每条一句话", .count(1...6))
  var points: [CitedDraft]
}
