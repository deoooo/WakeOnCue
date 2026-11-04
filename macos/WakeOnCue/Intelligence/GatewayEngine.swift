import Foundation
import Security

/// The user's OpenAI-compatible gateway: base URL and model in preferences, API key in the
/// keychain. Never part of the code or the repository.
nonisolated struct GatewayConfig: Sendable, Equatable {
  var baseURL: String
  var model: String
  var apiKey: String

  /// `https://host/v1` → `https://host/v1/chat/completions`; a full endpoint is kept as is.
  var endpoint: URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
      return nil
    }
    return trimmed.hasSuffix("/chat/completions") ? url : url.appending(path: "chat/completions")
  }

  var host: String { endpoint?.host() ?? baseURL }

  var isComplete: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty }
}

nonisolated enum GatewayError: LocalizedError {
  case notConfigured
  case http(Int, String)
  case badResponse(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured: "网关还没有设置好"
    case .http(let status, let body): "网关返回 \(status)：\(body.prefix(200))"
    case .badResponse(let detail): "网关的回复无法解析：\(detail.prefix(200))"
    }
  }
}

/// Summaries through an OpenAI-compatible `chat/completions` endpoint. Structure comes back as a
/// JSON object described in the prompt, so it works with gateways that do not support
/// `response_format`.
nonisolated struct GatewayEngine: SummaryEngine {
  let config: GatewayConfig

  var name: String { "网关 \(config.model)" }
  var destination: String? { config.host }
  var partCharacters: Int { 12_000 }

  func hour(_ prompt: String) async throws -> HourResult {
    struct Reply: Decodable {
      var summary: String
      var keySentences: [Int]?
    }
    let reply: Reply = try await json(prompt, shape: #"{"summary": "这一小时谈了什么，一到两句话", "keySentences": [最能代表这一小时内容的二到五句原话的编号]}"#)
    return HourResult(summary: reply.summary, keySentences: reply.keySentences ?? [])
  }

  func text(_ prompt: String) async throws -> String {
    try await complete(prompt)
  }

  func day(_ prompt: String) async throws -> DayResult {
    struct Reply: Decodable {
      var headline: Cited
      var details: [Cited]
    }
    let reply: Reply = try await json(
      prompt,
      shape: #"{"headline": {"text": "用一句话说出今天最重要的结果", "sources": [依据的原话编号]}, "details": [{"text": "当天的一条要点", "sources": [依据的原话编号，一到三个]}]}"#)
    return DayResult(headline: reply.headline.result, details: reply.details.prefix(6).map(\.result))
  }

  func points(_ prompt: String) async throws -> [CitedResult] {
    struct Reply: Decodable { var points: [Cited] }
    let reply: Reply = try await json(
      prompt, shape: #"{"points": [{"text": "一条会议要点", "sources": [依据的原话编号，一到三个]}]}"#)
    return reply.points.prefix(8).map(\.result)
  }

  private struct Cited: Decodable {
    var text: String
    var sources: [Int]?
    var result: CitedResult { CitedResult(text: text, sources: sources ?? []) }
  }

  private func json<T: Decodable>(_ prompt: String, shape: String) async throws -> T {
    let reply = try await complete(prompt + "\n\n只输出一个 JSON 对象，不要输出其他文字，格式如下：\n" + shape)
    var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    // Models often wrap JSON in a code fence or add a sentence around it.
    if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
      body = String(body[start...end])
    }
    do {
      return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    } catch {
      throw GatewayError.badResponse(reply)
    }
  }

  /// One chat completion with the shared instructions as the system message.
  func complete(_ prompt: String, system: String = SummaryPrompts.instructions, maxTokens: Int = 1_200) async throws -> String {
    guard let endpoint = config.endpoint, config.isComplete else { throw GatewayError.notConfigured }
    var request = URLRequest(url: endpoint, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "model": config.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": prompt],
      ],
      "temperature": 0.2,
      "max_tokens": maxTokens,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw GatewayError.http(status, String(decoding: data, as: UTF8.self))
    }
    struct Completion: Decodable {
      struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
      }
      var choices: [Choice]
    }
    guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
      let content = completion.choices.first?.message.content
    else { throw GatewayError.badResponse(String(decoding: data, as: UTF8.self)) }
    // Reasoning models may prepend their thinking; keep only the answer.
    if let end = content.range(of: "</think>") { return String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
    return content
  }

  /// "测试连接": a tiny request that shows whether the URL, model and key work.
  func test() async -> Result<String, Error> {
    let started = Date()
    do {
      let reply = try await complete("请只回复：连接正常", system: "你是连接测试。", maxTokens: 20)
      let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
      return .success("连接正常，用时 \(milliseconds) 毫秒。模型回复：\(reply.prefix(40))")
    } catch {
      return .failure(error)
    }
  }
}

/// The gateway's API key in the login keychain.
nonisolated enum GatewayKeychain {
  private static let service = "com.deoooo.WakeOnCue.macos.gateway"
  private static let account = "api-key"

  static func read() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  @discardableResult
  static func save(_ key: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard !key.isEmpty else { return true }
    var attributes = query
    attributes[kSecValueData as String] = Data(key.utf8)
    attributes[kSecAttrLabel as String] = "WakeOnCue AI 网关"
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
