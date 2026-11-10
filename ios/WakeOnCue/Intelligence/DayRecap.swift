import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// One sentence on what a day's conversations were about, written from their summaries, on
/// this iPhone with Apple Intelligence or by the service configured in Settings.
enum DayRecap {
  struct Conversation: Sendable {
    var time: String
    var title: String
    var overview: String
  }

  /// Changes whenever a conversation is added, removed or summarized again, so a cached
  /// sentence is written again only then.
  static func fingerprint(_ conversations: [(id: String, summarizedAt: Date)]) -> String {
    conversations
      .map { "\($0.id)@\(Int($0.summarizedAt.timeIntervalSince1970))" }
      .sorted()
      .joined(separator: ",")
  }

  static func write(
    _ conversations: [Conversation],
    language: AppLanguage,
    provider: LanguageModelProvider?
  ) async throws -> String {
    let output = language == .simplifiedChinese ? "Simplified Chinese" : "English"
    let system = """
      You write a one-sentence recap of someone's day from summaries of the conversations \
      they recorded. Mention the two or three most important things, in time order. \
      At most 40 words or 60 Chinese characters. Only use what the summaries say. \
      Write in \(output). Reply with the sentence only.
      """
    let user = conversations
      .map { "\($0.time) \($0.title): \($0.overview)" }
      .joined(separator: "\n")
    let text: String
    if let provider {
      text = try await ThirdPartyLanguageModel.complete(system: system, user: user, provider: provider)
    } else {
      text = try await onDevice(system: system, user: user)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
  }

  private static func onDevice(system: String, user: String) async throws -> String {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        let session = LanguageModelSession(instructions: system)
        return try await session.respond(to: user).content
      }
    #endif
    throw OnDeviceIntelligenceError.unavailable
  }
}

/// Day recaps already written, kept on this iPhone with the fingerprint they were written for.
@MainActor
enum DayRecapCache {
  private static let key = "day-recap.v1"

  private struct Entry: Codable {
    var fingerprint: String
    var text: String
  }

  static func text(day: String, fingerprint: String) -> String? {
    guard let entry = entries()[day], entry.fingerprint == fingerprint else { return nil }
    return entry.text
  }

  static func save(_ text: String, day: String, fingerprint: String) {
    var all = entries()
    all[day] = Entry(fingerprint: fingerprint, text: text)
    // Keeps the most recent year of days.
    if all.count > 400 {
      for old in all.keys.sorted().prefix(all.count - 400) { all[old] = nil }
    }
    if let data = try? JSONEncoder().encode(all) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  private static func entries() -> [String: Entry] {
    guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
    return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
  }
}
