import Foundation

/// Re-transcribes one sentence: the downloaded model on this Mac, or the user's transcription
/// service.
protocol SentenceRecognizer: Sendable {
  func recognize(_ samples: [Float]) async throws -> String
}

extension SherpaRecognizer: SentenceRecognizer {
  /// Off the caller's actor: decoding blocks for a second or so.
  @concurrent nonisolated func recognize(_ samples: [Float]) async throws -> String {
    transcribe(samples)
  }
}

/// The user's OpenAI-compatible transcription service (`POST {base}/audio/transcriptions`).
/// Base URL and model in preferences, key in the keychain; audio only leaves the Mac after the
/// user agreed for that host.
nonisolated struct TranscriptionServiceConfig: Sendable, Equatable {
  var baseURL: String
  var model: String
  var apiKey: String

  var endpoint: URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
      return nil
    }
    return trimmed.hasSuffix("/audio/transcriptions") ? url : url.appending(path: "audio/transcriptions")
  }

  var host: String { endpoint?.host() ?? baseURL }

  var isComplete: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty }
}

nonisolated struct RemoteTranscriber: SentenceRecognizer {
  let config: TranscriptionServiceConfig

  @concurrent func recognize(_ samples: [Float]) async throws -> String {
    var delay: Double = 2
    for attempt in 1...4 {
      do {
        return try await send(samples)
      } catch {
        let transient = (error as? GatewayError)?.isTransient ?? (error is URLError)
        guard transient, attempt < 4 else { throw error }
        try await Task.sleep(for: .seconds(delay))
        delay *= 2
      }
    }
    return ""
  }

  /// "测试连接": one second of silence; any 2xx with a `text` field counts.
  func test() async -> Result<String, Error> {
    let started = Date()
    do {
      _ = try await send([Float](repeating: 0, count: 16_000))
      return .success("连接正常，用时 \(Int(Date().timeIntervalSince(started) * 1_000)) 毫秒")
    } catch {
      return .failure(error)
    }
  }

  private func send(_ samples: [Float]) async throws -> String {
    guard let endpoint = config.endpoint, config.isComplete else { throw GatewayError.notConfigured }
    let boundary = "WakeOnCue-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("model", config.model)
    field("language", "zh")
    field("response_format", "json")
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sentence.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(Self.wav(samples))
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: endpoint, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw GatewayError.http(status, String(decoding: data, as: UTF8.self)) }
    struct Reply: Decodable { var text: String }
    guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
      throw GatewayError.badResponse(String(decoding: data, as: UTF8.self))
    }
    return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 16 kHz mono 16-bit PCM WAV.
  static func wav(_ samples: [Float]) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(Data("RIFF".utf8)); append(36 + bytes); data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8)); append(bytes)
    for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
    return data
  }
}
