import XCTest

@testable import WakeOnCue

@MainActor
final class AIProviderSettingsTests: XCTestCase {
  private var settings: AppSettings!

  override func setUp() async throws {
    settings = AppSettings()
    try clearProviders()
  }

  override func tearDown() async throws {
    try clearProviders()
    settings = nil
  }

  private func clearProviders() throws {
    settings.selectSpeechEngine(.apple)
    settings.selectLanguageModelEngine(.apple)
    try settings.persistAIProviders(settings.aiProviderDraft, speech: nil, languageModel: nil)
  }

  private func saveLanguageModel(_ engine: LanguageModelEngine, url: String, key: String) throws {
    settings.selectLanguageModelEngine(engine)
    settings.languageModelBaseURL = url
    settings.languageModelName = "model"
    settings.languageModelAPIKey = key
    try settings.persistAIProviders(
      settings.aiProviderDraft,
      speech: nil,
      languageModel: settings.candidateLanguageModelProvider()
    )
  }

  func testBlankKeyKeepsStoredKeyOnlyForTheSameService() throws {
    try saveLanguageModel(.openAICompatible, url: "https://one.example.com/v1", key: "stored")
    XCTAssertEqual(settings.languageModelAPIKey, "")

    XCTAssertEqual(try settings.candidateLanguageModelProvider()?.endpoint.apiKey, "stored")

    settings.languageModelBaseURL = "https://two.example.com/v1"
    XCTAssertThrowsError(try settings.candidateLanguageModelProvider()) {
      XCTAssertEqual($0 as? ThirdPartyAIError, .apiKeyRequired)
    }
  }

  func testStoredKeyIsNotSentOverAnotherProtocol() throws {
    try saveLanguageModel(.openAICompatible, url: "https://one.example.com", key: "stored")
    settings.languageModelEngine = .anthropic
    XCTAssertThrowsError(try settings.candidateLanguageModelProvider()) {
      XCTAssertEqual($0 as? ThirdPartyAIError, .apiKeyRequired)
    }
  }

  func testChoosingAnotherEngineStartsFromItsDefaults() throws {
    try saveLanguageModel(.openAICompatible, url: "https://groq.example.com/v1", key: "stored")
    settings.languageModelAPIKey = "typed"

    settings.selectLanguageModelEngine(.openAICompatible)
    XCTAssertEqual(settings.languageModelBaseURL, "https://groq.example.com/v1")
    XCTAssertEqual(settings.languageModelAPIKey, "typed")

    settings.selectLanguageModelEngine(.anthropic)
    XCTAssertEqual(settings.languageModelBaseURL, "")
    XCTAssertEqual(settings.languageModelName, "")
    XCTAssertEqual(settings.languageModelAPIKey, "")

    settings.languageModelName = "claude"
    settings.languageModelAPIKey = "anthropic-key"
    let provider = try XCTUnwrap(settings.candidateLanguageModelProvider())
    XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.anthropic.com")
    XCTAssertEqual(provider.wireProtocol, .anthropic)
  }

  func testSavesTheCheckedDraftEvenIfTheFormChangedMeanwhile() throws {
    settings.selectLanguageModelEngine(.openAICompatible)
    settings.languageModelBaseURL = " https://checked.example.com/v1 "
    settings.languageModelName = "model"
    settings.languageModelAPIKey = "new-key"
    let draft = settings.aiProviderDraft
    let provider = try settings.candidateLanguageModelProvider()

    settings.languageModelBaseURL = "https://other.example.com/v1"
    try settings.persistAIProviders(draft, speech: nil, languageModel: provider)

    XCTAssertEqual(
      settings.activeLanguageModelProvider?.endpoint.baseURL.absoluteString,
      "https://checked.example.com/v1")
    XCTAssertEqual(settings.activeLanguageModelProvider?.endpoint.apiKey, "new-key")
    XCTAssertEqual(try settings.candidateLanguageModelProvider()?.endpoint.apiKey, "new-key")
  }

  func testTurningAServiceOffDeletesItsKey() throws {
    try saveLanguageModel(.openAICompatible, url: "https://one.example.com/v1", key: "stored")
    try clearProviders()
    XCTAssertNil(settings.activeLanguageModelProvider)
    XCTAssertEqual(
      try KeychainStore.read(service: "com.deoooo.WakeOnCue.ai", account: "language-model-api-key"),
      "")
  }

  func testChoosingAnotherSpeechEngineClearsItsFields() {
    settings.selectSpeechEngine(.openAICompatible)
    settings.speechBaseURL = "https://groq.example.com/v1"
    settings.speechModel = "whisper"
    settings.speechAPIKey = "typed"

    settings.selectSpeechEngine(.openAICompatible)
    XCTAssertEqual(settings.speechBaseURL, "https://groq.example.com/v1")

    settings.selectSpeechEngine(.apple)
    XCTAssertEqual(settings.speechBaseURL, "")
    XCTAssertEqual(settings.speechModel, "")
    XCTAssertEqual(settings.speechAPIKey, "")
  }
}
