import Foundation
import Security

/// The wire protocol a gateway speaks.
nonisolated enum GatewayProtocol: String, CaseIterable, Sendable {
  case chatCompletions
  case responses
  case anthropic

  var label: String {
    switch self {
    case .chatCompletions: "OpenAI Chat Completions"
    case .responses: "OpenAI Responses"
    case .anthropic: "Claude（Anthropic Messages）"
    }
  }

  var defaultBaseURL: String {
    switch self {
    case .chatCompletions, .responses: "https://api.openai.com/v1"
    case .anthropic: "https://api.anthropic.com"
    }
  }

  /// The path added to the base URL; a base URL that already ends with it is used as is.
  fileprivate var path: String {
    switch self {
    case .chatCompletions: "chat/completions"
    case .responses: "responses"
    case .anthropic: "v1/messages"
    }
  }
}

/// The user's gateway: protocol, base URL and model in preferences, API key in the keychain.
/// Never part of the code or the repository.
nonisolated struct GatewayConfig: Sendable, Equatable {
  var kind: GatewayProtocol = .chatCompletions
  var baseURL: String
  var model: String
  var apiKey: String
  /// Claude only: send the key as `Authorization: Bearer` for gateways that only accept that.
  var bearerForAnthropic = false

  /// `https://host/v1` → `https://host/v1/chat/completions`; `https://api.anthropic.com` →
  /// `https://api.anthropic.com/v1/messages`, and `…/v1` → `…/v1/messages`.
  var endpoint: URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
      return nil
    }
    let path = kind.path
    if trimmed.hasSuffix("/" + path) { return url }
    if kind == .anthropic, trimmed.hasSuffix("/v1") { return url.appending(path: "messages") }
    return url.appending(path: path)
  }

  var host: String { endpoint?.host() ?? baseURL }

  var isComplete: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty }
}

nonisolated enum GatewayError: LocalizedError {
  case notConfigured
  case http(Int, String)
  case badResponse(String)
  case truncated

  var errorDescription: String? {
    switch self {
    case .notConfigured: "网关还没有设置好"
    case .http(let status, let body): "服务返回 HTTP \(status)：\(GatewayError.message(in: body))"
    case .badResponse(let detail): "网关的回复无法解析：\(detail.prefix(160))"
    case .truncated: "模型的回复超出了输出长度上限，没有给出结果"
    }
  }

  /// Retrying helps with rate limits, server errors and time-outs, not with a bad key or request.
  var isTransient: Bool {
    if case .http(let status, _) = self { return status == 408 || status == 429 || status >= 500 }
    return false
  }

  /// The error message from an OpenAI or Anthropic error body, or the body itself.
  static func message(in body: String) -> String {
    struct Body: Decodable {
      struct Inner: Decodable { var message: String? }
      var error: Inner?
    }
    if let parsed = try? JSONDecoder().decode(Body.self, from: Data(body.utf8)), let message = parsed.error?.message {
      return message
    }
    return String(body.prefix(160))
  }
}

/// Summaries through the user's gateway. Structure comes back as a JSON object described in the
/// prompt (a reply that does not parse is asked for once more), so nothing depends on one
/// vendor's structured-output feature. Time-outs, 429 and 5xx are retried with backoff.
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
    let request = prompt + "\n\n只输出一个 JSON 对象，不要输出其他文字，格式如下：\n" + shape
    var reply = try await complete(request, json: true)
    if let value: T = Self.decode(reply) { return value }
    // One more try, telling the model what went wrong.
    reply = try await complete(request + "\n\n上一次的回复不是合法的 JSON。这次只输出 JSON 对象本身。", json: true)
    if let value: T = Self.decode(reply) { return value }
    throw GatewayError.badResponse(reply)
  }

  static func decode<T: Decodable>(_ reply: String) -> T? {
    var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    // Models often wrap JSON in a code fence or add a sentence around it.
    if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end {
      body = String(body[start...end])
    }
    return try? JSONDecoder().decode(T.self, from: Data(body.utf8))
  }

  /// One completion in the configured protocol, retried with backoff on transient failures.
  /// Reasoning models count their thinking against the output limit, so leave plenty of room.
  func complete(_ prompt: String, system: String = SummaryPrompts.instructions, maxTokens: Int = 8_000, json: Bool = false, attempts: Int = 4) async throws -> String {
    var delay: Double = 2
    for attempt in 1...attempts {
      do {
        return try await send(prompt, system: system, maxTokens: maxTokens, json: json)
      } catch {
        let transient = (error as? GatewayError)?.isTransient ?? (error is URLError)
        guard transient, attempt < attempts else { throw error }
        try await Task.sleep(for: .seconds(delay))
        delay *= 2
      }
    }
    throw GatewayError.notConfigured
  }

  private func send(_ prompt: String, system: String, maxTokens: Int, json: Bool) async throws -> String {
    guard let endpoint = config.endpoint, config.isComplete else { throw GatewayError.notConfigured }
    var request = URLRequest(url: endpoint, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["model": config.model]
    // JSON mode is only turned on where it is known to exist, so other gateways never reject it.
    let officialOpenAI = config.host == "api.openai.com"
    switch config.kind {
    case .chatCompletions:
      request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
      body["messages"] = [["role": "system", "content": system], ["role": "user", "content": prompt]]
      body["max_tokens"] = maxTokens
      body["temperature"] = 0.2
      if json && officialOpenAI { body["response_format"] = ["type": "json_object"] }
    case .responses:
      request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
      body["instructions"] = system
      body["input"] = prompt
      body["max_output_tokens"] = max(maxTokens, 16)
      if json && officialOpenAI { body["text"] = ["format": ["type": "json_object"]] }
    case .anthropic:
      if config.bearerForAnthropic {
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
      } else {
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
      }
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      body["system"] = system
      body["messages"] = [["role": "user", "content": prompt]]
      body["max_tokens"] = maxTokens
      body["temperature"] = 0.2
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw GatewayError.http(status, String(decoding: data, as: UTF8.self))
    }
    guard let text = Self.text(in: data, kind: config.kind), !text.isEmpty else {
      let raw = String(decoding: data, as: UTF8.self)
      // A reasoning model that used up the limit while thinking returns no content at all.
      if raw.contains("\"length\"") || raw.contains("max_tokens") || raw.contains("max_output_tokens") { throw GatewayError.truncated }
      throw GatewayError.badResponse(raw)
    }
    // Reasoning models may prepend their thinking; keep only the answer.
    if let end = text.range(of: "</think>") { return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
    return text
  }

  /// The reply text: `choices[0].message.content`, the message parts of a Responses `output`,
  /// or the text blocks of an Anthropic `content`.
  static func text(in data: Data, kind: GatewayProtocol) -> String? {
    switch kind {
    case .chatCompletions:
      struct Completion: Decodable {
        struct Choice: Decodable {
          struct Message: Decodable { var content: String? }
          var message: Message
        }
        var choices: [Choice]
      }
      return (try? JSONDecoder().decode(Completion.self, from: data))?.choices.first?.message.content
    case .responses:
      struct Response: Decodable {
        struct Item: Decodable {
          struct Part: Decodable {
            var type: String
            var text: String?
          }
          var type: String
          var content: [Part]?
        }
        var output: [Item]
      }
      guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
      var parts: [String] = []
      for item in response.output where item.type == "message" {
        for part in item.content ?? [] where part.type == "output_text" || part.type == "text" {
          if let text = part.text { parts.append(text) }
        }
      }
      return parts.isEmpty ? nil : parts.joined()
    case .anthropic:
      struct Message: Decodable {
        struct Block: Decodable {
          var type: String
          var text: String?
        }
        var content: [Block]
      }
      guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return nil }
      let texts = message.content.filter { $0.type == "text" }.compactMap(\.text)
      return texts.isEmpty ? nil : texts.joined()
    }
  }

  /// "测试连接": a tiny request in the chosen protocol, without retries, so the real error shows.
  func test() async -> Result<String, Error> {
    let started = Date()
    do {
      let reply = try await complete("请只回复：连接正常", system: "你是连接测试。", maxTokens: 512, attempts: 1)
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
  static let gatewayAccount = "api-key"
  static let transcriptionAccount = "transcription-api-key"

  static func read(account: String = gatewayAccount) -> String {
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
  static func save(_ key: String, account: String = gatewayAccount) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard !key.isEmpty else { return true }
    var attributes = query
    attributes[kSecValueData as String] = Data(key.utf8)
    attributes[kSecAttrLabel as String] = account == gatewayAccount ? "WakeOnCue AI 网关" : "WakeOnCue 转录服务"
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
