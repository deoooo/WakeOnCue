import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class ThirdPartyAITests: XCTestCase {
  private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private let openAIEndpoint = ThirdPartyEndpoint(
    baseURL: URL(string: "https://llm.example.com/v1")!, model: "test-model", apiKey: "secret")

  override func tearDown() {
    StubURLProtocol.reset()
    super.tearDown()
  }

  func testEndpointValidationProtectsKeysFromPlainHTTP() throws {
    XCTAssertThrowsError(
      try ThirdPartyEndpoint.validated(baseURL: "http://api.example.com/v1", model: "m", apiKey: "k")
    ) { XCTAssertEqual($0 as? ThirdPartyAIError, .invalidBaseURL) }
    XCTAssertThrowsError(
      try ThirdPartyEndpoint.validated(baseURL: "http://172.32.0.1/v1", model: "m", apiKey: "k"))
    XCTAssertThrowsError(
      try ThirdPartyEndpoint.validated(baseURL: "https://user:pw@example.com", model: "m", apiKey: "k"))
    XCTAssertThrowsError(
      try ThirdPartyEndpoint.validated(baseURL: "https://example.com/v1", model: " ", apiKey: "k")
    ) { XCTAssertEqual($0 as? ThirdPartyAIError, .modelRequired) }
    XCTAssertThrowsError(
      try ThirdPartyEndpoint.validated(baseURL: "https://example.com/v1", model: "m", apiKey: "")
    ) { XCTAssertEqual($0 as? ThirdPartyAIError, .apiKeyRequired) }

    XCTAssertEqual(
      try ThirdPartyEndpoint.validated(baseURL: "http://192.168.1.5:8080/v1", model: "m", apiKey: "").apiKey,
      "")
    XCTAssertNoThrow(
      try ThirdPartyEndpoint.validated(baseURL: "http://mac.local:9000/v1", model: "m", apiKey: ""))
    XCTAssertNoThrow(
      try ThirdPartyEndpoint.validated(baseURL: " https://api.example.com/v1 ", model: "m", apiKey: "k"))
  }

  func testOpenAIRequestAndResponseShape() async throws {
    StubURLProtocol.responses = [
      .init(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#)
    ]
    let text = try await ThirdPartyLanguageModel.complete(
      system: "sys", user: "hi",
      provider: LanguageModelProvider(wireProtocol: .openAI, endpoint: openAIEndpoint),
      session: session())
    XCTAssertEqual(text, "hello")

    let request = try XCTUnwrap(StubURLProtocol.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: StubURLProtocol.bodies[0]) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "test-model")
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
  }

  func testAnthropicRequestAndResponseShape() async throws {
    StubURLProtocol.responses = [
      .init(status: 200, body: #"{"content":[{"type":"text","text":"hel"},{"type":"text","text":"lo"}]}"#)
    ]
    let text = try await ThirdPartyLanguageModel.complete(
      system: "sys", user: "hi",
      provider: LanguageModelProvider(
        wireProtocol: .anthropic,
        endpoint: ThirdPartyEndpoint(
          baseURL: URL(string: "https://api.anthropic.com")!, model: "claude", apiKey: "secret")),
      session: session())
    XCTAssertEqual(text, "hello")

    let request = try XCTUnwrap(StubURLProtocol.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: StubURLProtocol.bodies[0]) as? [String: Any])
    XCTAssertEqual(body["system"] as? String, "sys")
    XCTAssertNotNil(body["max_tokens"] as? Int)
  }

  func testAnthropicBaseURLEndingInV1IsNotDoubled() throws {
    let request = try ThirdPartyLanguageModel.request(
      system: "s", user: "u",
      provider: LanguageModelProvider(
        wireProtocol: .anthropic,
        endpoint: ThirdPartyEndpoint(
          baseURL: URL(string: "https://gateway.example.com/anthropic/v1")!, model: "m", apiKey: "k")))
    XCTAssertEqual(request.url?.absoluteString, "https://gateway.example.com/anthropic/v1/messages")
  }

  func testServiceErrorSurfacesMessageWithoutKey() async {
    StubURLProtocol.responses = [
      .init(status: 401, body: #"{"error":{"message":"Invalid API key"}}"#)
    ]
    do {
      _ = try await ThirdPartyLanguageModel.complete(
        system: "s", user: "u",
        provider: LanguageModelProvider(wireProtocol: .openAI, endpoint: openAIEndpoint),
        session: session())
      XCTFail("Expected failure")
    } catch {
      XCTAssertEqual(
        error as? ThirdPartyAIError, .requestFailed(status: 401, message: "Invalid API key"))
      XCTAssertFalse(error.localizedDescription.contains("secret"))
    }
  }

  func testJSONIsReadFromFencedModelReply() throws {
    struct Value: Decodable { let answer: String }
    let reply = "Sure:\n```json\n{\"answer\": \"yes\"}\n```"
    XCTAssertEqual(
      try ThirdPartyLanguageModel.decodeJSONObject(Value.self, from: reply).answer, "yes")
    XCTAssertThrowsError(try ThirdPartyLanguageModel.decodeJSONObject(Value.self, from: "no json"))
  }

  func testSummaryRecordsWhichModelWroteIt() async throws {
    StubURLProtocol.responses = [
      .init(
        status: 200,
        body: #"{"choices":[{"message":{"content":"{\"title\":\"T\",\"overview\":\"O\",\"keyPoints\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\"]}"}}]}"#)
    ]
    let summary = try await ThirdPartyIntelligence.summarize(
      [event("one", start: 0)], title: "Standup", language: .english,
      provider: LanguageModelProvider(wireProtocol: .openAI, endpoint: openAIEndpoint),
      session: session())
    XCTAssertEqual(summary.title, "T")
    XCTAssertEqual(summary.keyPoints.count, 6)
    XCTAssertEqual(summary.actionItems, [])
    XCTAssertEqual(summary.generatedBy, "test-model")
    XCTAssertEqual(StubURLProtocol.requests.count, 1)
  }

  func testAnswerOmitsSpeakerNamesAndIgnoresInventedSources() async throws {
    StubURLProtocol.responses = [
      .init(
        status: 200,
        body: #"{"choices":[{"message":{"content":"{\"answerable\":true,\"answer\":\"Monday\",\"sources\":[2,99,2]}"}}]}"#)
    ]
    let answer = await RecordingQuestionAnswering.answer(
      question: "When?",
      citations: [citation("a", speaker: "Alice Secret"), citation("b", speaker: "Bob Secret")],
      language: .english,
      provider: LanguageModelProvider(wireProtocol: .openAI, endpoint: openAIEndpoint),
      session: session())
    XCTAssertEqual(answer.text, "Monday")
    XCTAssertEqual(answer.sources.map(\.segment.segmentID), ["b"])
    let sent = String(decoding: StubURLProtocol.bodies[0], as: UTF8.self)
    XCTAssertFalse(sent.contains("Secret"))
    XCTAssertTrue(sent.contains("spoken text a"))
  }

  func testFailedAnswerKeepsMatchingPassages() async {
    StubURLProtocol.responses = [.init(status: 500, body: "oops")]
    let answer = await RecordingQuestionAnswering.answer(
      question: "When?", citations: [citation("a", speaker: nil)], language: .english,
      provider: LanguageModelProvider(wireProtocol: .openAI, endpoint: openAIEndpoint),
      session: session())
    XCTAssertNil(answer.text)
    XCTAssertEqual(answer.sources.count, 1)
    guard case .failed = answer.notice else { return XCTFail("Expected failed notice") }
  }

  func testPartRangesCoverLongRecordingsWithoutGaps() {
    XCTAssertEqual(ThirdPartyTranscriber.partRanges(duration: 90), [0..<90])
    XCTAssertEqual(ThirdPartyTranscriber.partRanges(duration: 1_200), [0..<1_200])
    let parts = ThirdPartyTranscriber.partRanges(duration: 3_000)
    XCTAssertEqual(parts, [0..<1_200, 1_200..<2_400, 2_400..<3_000])
  }

  func testTranscriptionRequestReadsTimedSegments() async throws {
    StubURLProtocol.responses = [
      .init(
        status: 200,
        body: #"{"text":"a b","segments":[{"id":0,"start":0.5,"end":1.5,"text":" a"},{"id":1,"start":1.5,"end":2.0,"text":" b"}]}"#)
    ]
    let segments = try await ThirdPartyTranscriber.transcribePart(
      audio: Data([1, 2, 3]), filename: "a.m4a", language: "zh", partDuration: 2,
      endpoint: openAIEndpoint, session: session())
    XCTAssertEqual(segments.map(\.text), [" a", " b"])

    let request = try XCTUnwrap(StubURLProtocol.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/audio/transcriptions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    let body = String(decoding: StubURLProtocol.bodies[0], as: UTF8.self)
    XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ntest-model"))
    XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
    XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
    XCTAssertTrue(body.contains("name=\"file\"; filename=\"a.m4a\""))
  }

  func testTextOnlyModelsFallBackToPlainJSON() async throws {
    StubURLProtocol.responses = [
      .init(status: 400, body: #"{"error":{"message":"verbose_json is not supported"}}"#),
      .init(status: 200, body: #"{"text":" hello there "}"#),
    ]
    let segments = try await ThirdPartyTranscriber.transcribePart(
      audio: Data([1]), filename: "a.m4a", language: nil, partDuration: 42,
      endpoint: openAIEndpoint, session: session())
    XCTAssertEqual(segments, [.init(start: 0, end: 42, text: "hello there")])
    XCTAssertEqual(StubURLProtocol.requests.count, 2)
    let retry = String(decoding: StubURLProtocol.bodies[1], as: UTF8.self)
    XCTAssertTrue(retry.contains("name=\"response_format\"\r\n\r\njson"))
    XCTAssertFalse(retry.contains("timestamp_granularities"))
    XCTAssertFalse(retry.contains("name=\"language\""))
  }

  func testRejectedKeyIsNotRetriedAsTextOnly() async {
    StubURLProtocol.responses = [.init(status: 401, body: #"{"error":{"message":"bad key"}}"#)]
    do {
      _ = try await ThirdPartyTranscriber.transcribePart(
        audio: Data([1]), filename: "a.m4a", language: nil, partDuration: 1,
        endpoint: openAIEndpoint, session: session())
      XCTFail("Expected failure")
    } catch {
      XCTAssertEqual(error as? ThirdPartyAIError, .requestFailed(status: 401, message: "bad key"))
    }
    XCTAssertEqual(StubURLProtocol.requests.count, 1)
  }

  func testSilentWAVHasValidHeader() {
    let wav = ThirdPartyTranscriber.silentWAV(seconds: 1)
    XCTAssertEqual(wav.count, 44 + 32_000)
    XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
  }

  func testFullFileTranscriptionUsesRealAudioAndAssignsTimestamps() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "source.wav")
    try ThirdPartyTranscriber.silentWAV(seconds: 2).write(to: url)
    StubURLProtocol.responses = [
      .init(status: 200, body: #"{"segments":[{"start":0.25,"end":1.0,"text":" hi "},{"start":1,"end":2,"text":"  "}]}"#)
    ]
    let events = try await ThirdPartyTranscriber.transcribe(
      audioURL: url, recordingID: "rec_1", language: nil, endpoint: openAIEndpoint, session: session())
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].recordingID, "rec_1")
    XCTAssertEqual(events[0].text, "hi")
    XCTAssertEqual(events[0].startMilliseconds, 250)
    XCTAssertEqual(events[0].endMilliseconds, 1_000)
    XCTAssertTrue(events[0].isFinal)
  }

  func testLongRecordingIsSplitIntoEncodedPartsWithContinuousTimestamps() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "source.wav")
    try ThirdPartyTranscriber.silentWAV(seconds: 21 * 60, sampleRate: 8_000).write(to: url)
    StubURLProtocol.responses = [
      .init(status: 200, body: #"{"segments":[{"start":10,"end":11,"text":"first"}]}"#),
      .init(status: 200, body: #"{"segments":[{"start":5,"end":6,"text":"second"}]}"#),
    ]
    let events = try await ThirdPartyTranscriber.transcribe(
      audioURL: url, recordingID: "rec_1", language: nil, endpoint: openAIEndpoint, session: session())
    XCTAssertEqual(StubURLProtocol.requests.count, 2)
    XCTAssertEqual(events.map(\.text), ["first", "second"])
    XCTAssertEqual(events.map(\.startMilliseconds), [10_000, 1_205_000])
    XCTAssertEqual(events.map(\.segmentID), ["cloud_1", "cloud_2"])
    for body in StubURLProtocol.bodies {
      XCTAssertLessThan(body.count, ThirdPartyTranscriber.maxUploadBytes)
      XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(".m4a\""))
    }
  }

  private func event(_ text: String, start: Int) -> RealtimeTranscriptEvent {
    RealtimeTranscriptEvent(
      recordingID: "rec", segmentID: text, revision: 1, startMilliseconds: start,
      endMilliseconds: start + 1_000, text: text, isFinal: true, speaker: nil)
  }

  private func citation(_ id: String, speaker: String?) -> RecordingCitation {
    RecordingCitation(
      recording: RecordingRecord(
        id: "rec", createdAt: .now, startedAt: .now, status: .completed, localAudioPath: "/tmp/a",
        uploadStatus: .completed, deviceModel: "test", appVersion: "1"),
      segment: RealtimeTranscriptEvent(
        recordingID: "rec", segmentID: id, revision: 1, startMilliseconds: 0,
        endMilliseconds: 1_000, text: "spoken text \(id)", isFinal: true, speaker: nil),
      recordingTitle: nil,
      score: 1,
      speakerName: speaker)
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Response {
    let status: Int
    let body: String
  }

  nonisolated(unsafe) static var responses: [Response] = []
  nonisolated(unsafe) static var requests: [URLRequest] = []
  nonisolated(unsafe) static var bodies: [Data] = []

  static func reset() {
    responses = []
    requests = []
    bodies = []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    Self.requests.append(request)
    Self.bodies.append(Self.readBody(of: request))
    let stub = Self.responses.isEmpty ? Response(status: 500, body: "no stub") : Self.responses.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func readBody(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
