import Foundation
import Observation
import Security
import SwiftUI
import WakeOnCueCore

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  static let preferenceKey = "app-appearance"

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .system: "Follow System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

@MainActor
@Observable
final class AppSettings {
  static let spokenLanguageKey = "realtime-processing.spoken-language"
  private static let retiredRealtimeServiceKey = "realtime-processing.retired"
  private static let realtimeKeychainService = "com.deoooo.WakeOnCue.realtime"
  private static let voiceNamesAccount = "remembered-voice-names"
  private static let aiKeychainService = "com.deoooo.WakeOnCue.ai"
  private static let speechKeyAccount = "speech-api-key"
  private static let languageModelKeyAccount = "language-model-api-key"
  private static let speechEngineKey = "ai.speech.engine"
  private static let speechBaseURLKey = "ai.speech.base-url"
  private static let speechModelKey = "ai.speech.model"
  private static let languageModelEngineKey = "ai.language-model.engine"
  private static let languageModelBaseURLKey = "ai.language-model.base-url"
  private static let languageModelNameKey = "ai.language-model.model"

  var spokenLanguage = SpokenLanguage.automatic {
    didSet {
      UserDefaults.standard.set(spokenLanguage.rawValue, forKey: Self.spokenLanguageKey)
    }
  }
  var language = AppLanguage.system {
    didSet { language.persist() }
  }
  var appearance = AppAppearance.system {
    didSet {
      UserDefaults.standard.set(appearance.rawValue, forKey: AppAppearance.preferenceKey)
    }
  }
  var speechEngine = SpeechEngine.apple
  var speechBaseURL = ""
  var speechModel = ""
  var speechAPIKey = ""
  var languageModelEngine = LanguageModelEngine.apple
  var languageModelBaseURL = ""
  var languageModelName = ""
  var languageModelAPIKey = ""
  /// The saved services in use; nil means Apple's on-device frameworks.
  private(set) var activeSpeechEndpoint: ThirdPartyEndpoint?
  private(set) var activeLanguageModelProvider: LanguageModelProvider?
  /// Names of people an older version recognized, so old transcripts keep showing them.
  private var rememberedVoiceNames: [String: String] = [:]

  init() {
    language = AppLanguage.current
    if let rawAppearance = UserDefaults.standard.string(forKey: AppAppearance.preferenceKey),
      let storedAppearance = AppAppearance(rawValue: rawAppearance)
    {
      appearance = storedAppearance
    }
    Self.retireRealtimeService()
    restorePersistedSettings()
  }

  /// Names shown for person IDs the processor recognized, including the user.
  var personNames: [String: String] {
    var names = rememberedVoiceNames
    names[RealtimeSpeaker.selfPersonID] = AppLanguage.localized("Me")
    return names
  }

  /// Older versions saved a Gateway token and voiceprints, which have no use without the
  /// Gateway. They are deleted once, keeping only the names old transcripts refer to. A locked
  /// Keychain throws, so this runs again on the next launch.
  static func retireRealtimeService(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: retiredRealtimeServiceKey) else { return }
    struct RetiredVoice: Decodable {
      let id: String
      let name: String
    }
    do {
      let stored = try KeychainStore.read(service: realtimeKeychainService, account: "saved-voices")
      let voices = stored.flatMap { try? JSONDecoder().decode([RetiredVoice].self, from: Data($0.utf8)) } ?? []
      if !voices.isEmpty {
        let names = Dictionary(voices.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        try KeychainStore.save(
          String(decoding: try JSONEncoder().encode(names), as: UTF8.self),
          service: realtimeKeychainService,
          account: voiceNamesAccount
        )
      }
      for account in ["gateway-token", "self-voiceprint", "saved-voices"] {
        try KeychainStore.delete(service: realtimeKeychainService, account: account)
      }
    } catch {
      return
    }
    for key in [
      "realtime-processing.enabled", "realtime-processing.gateway-url",
      "speakers.diarization-enabled", "speakers.remember-voices",
    ] {
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: retiredRealtimeServiceKey)
  }

  /// A different service starts from its own default address and a fresh key.
  func selectSpeechEngine(_ engine: SpeechEngine) {
    guard engine != speechEngine else { return }
    speechEngine = engine
    speechBaseURL = ""
    speechModel = ""
    speechAPIKey = ""
  }

  func selectLanguageModelEngine(_ engine: LanguageModelEngine) {
    guard engine != languageModelEngine else { return }
    languageModelEngine = engine
    languageModelBaseURL = ""
    languageModelName = ""
    languageModelAPIKey = ""
  }

  var aiProviderDraft: AIProviderDraft {
    AIProviderDraft(
      speechEngine: speechEngine,
      speechBaseURL: speechBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      speechModel: speechModel.trimmingCharacters(in: .whitespacesAndNewlines),
      languageModelEngine: languageModelEngine,
      languageModelBaseURL: languageModelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      languageModelName: languageModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// The endpoint being edited, or nil when Apple's on-device speech is selected. A blank key
  /// keeps the stored one only for the same URL, so it is never sent to a different service.
  func candidateSpeechEndpoint() throws -> ThirdPartyEndpoint? {
    let draft = aiProviderDraft
    guard let defaultURL = draft.speechEngine.defaultBaseURL else { return nil }
    let baseURL = draft.speechBaseURL.isEmpty ? defaultURL : draft.speechBaseURL
    let isUnchanged = activeSpeechEndpoint?.baseURL.absoluteString == baseURL
    return try ThirdPartyEndpoint.validated(
      baseURL: baseURL,
      model: draft.speechModel,
      apiKey: speechAPIKey.isEmpty && isUnchanged
        ? (activeSpeechEndpoint?.apiKey ?? "") : speechAPIKey
    )
  }

  func candidateLanguageModelProvider() throws -> LanguageModelProvider? {
    let draft = aiProviderDraft
    guard let defaultURL = draft.languageModelEngine.defaultBaseURL else { return nil }
    let wireProtocol: LanguageModelProvider.WireProtocol =
      draft.languageModelEngine == .anthropic ? .anthropic : .openAI
    let baseURL = draft.languageModelBaseURL.isEmpty ? defaultURL : draft.languageModelBaseURL
    let isUnchanged =
      activeLanguageModelProvider?.wireProtocol == wireProtocol
      && activeLanguageModelProvider?.endpoint.baseURL.absoluteString == baseURL
    return LanguageModelProvider(
      wireProtocol: wireProtocol,
      endpoint: try ThirdPartyEndpoint.validated(
        baseURL: baseURL,
        model: draft.languageModelName,
        apiKey: languageModelAPIKey.isEmpty && isUnchanged
          ? (activeLanguageModelProvider?.endpoint.apiKey ?? "") : languageModelAPIKey
      )
    )
  }

  /// Keys are deleted as soon as a service is turned off. Both keys change together, so a
  /// failure cannot leave one service's key beside another service's address.
  func persistAIProviders(
    _ draft: AIProviderDraft,
    speech: ThirdPartyEndpoint?,
    languageModel: LanguageModelProvider?
  ) throws {
    let previousSpeechKey = try KeychainStore.read(
      service: Self.aiKeychainService, account: Self.speechKeyAccount)
    try KeychainStore.save(
      speech?.apiKey ?? "", service: Self.aiKeychainService, account: Self.speechKeyAccount)
    do {
      try KeychainStore.save(
        languageModel?.endpoint.apiKey ?? "",
        service: Self.aiKeychainService,
        account: Self.languageModelKeyAccount
      )
    } catch {
      try? KeychainStore.save(
        previousSpeechKey ?? "", service: Self.aiKeychainService, account: Self.speechKeyAccount)
      throw error
    }
    let defaults = UserDefaults.standard
    defaults.set(draft.speechEngine.rawValue, forKey: Self.speechEngineKey)
    defaults.set(draft.speechBaseURL, forKey: Self.speechBaseURLKey)
    defaults.set(draft.speechModel, forKey: Self.speechModelKey)
    defaults.set(draft.languageModelEngine.rawValue, forKey: Self.languageModelEngineKey)
    defaults.set(draft.languageModelBaseURL, forKey: Self.languageModelBaseURLKey)
    defaults.set(draft.languageModelName, forKey: Self.languageModelNameKey)
    restorePersistedAIProviders()
  }

  private func restorePersistedAIProviders() {
    let defaults = UserDefaults.standard
    speechEngine =
      SpeechEngine(rawValue: defaults.string(forKey: Self.speechEngineKey) ?? "") ?? .apple
    speechBaseURL = defaults.string(forKey: Self.speechBaseURLKey) ?? ""
    speechModel = defaults.string(forKey: Self.speechModelKey) ?? ""
    speechAPIKey = ""
    languageModelEngine =
      LanguageModelEngine(rawValue: defaults.string(forKey: Self.languageModelEngineKey) ?? "")
      ?? .apple
    languageModelBaseURL = defaults.string(forKey: Self.languageModelBaseURLKey) ?? ""
    languageModelName = defaults.string(forKey: Self.languageModelNameKey) ?? ""
    languageModelAPIKey = ""

    activeSpeechEndpoint = speechEngine.defaultBaseURL.flatMap { defaultURL in
      try? ThirdPartyEndpoint.validated(
        baseURL: speechBaseURL.isEmpty ? defaultURL : speechBaseURL,
        model: speechModel,
        apiKey: (try? KeychainStore.read(
          service: Self.aiKeychainService, account: Self.speechKeyAccount)) ?? ""
      )
    }
    activeLanguageModelProvider = languageModelEngine.defaultBaseURL.flatMap { defaultURL in
      (try? ThirdPartyEndpoint.validated(
        baseURL: languageModelBaseURL.isEmpty ? defaultURL : languageModelBaseURL,
        model: languageModelName,
        apiKey: (try? KeychainStore.read(
          service: Self.aiKeychainService, account: Self.languageModelKeyAccount)) ?? ""
      )).map {
        LanguageModelProvider(
          wireProtocol: languageModelEngine == .anthropic ? .anthropic : .openAI, endpoint: $0)
      }
    }
  }

  func restorePersistedSettings() {
    spokenLanguage = SpokenLanguage(
      rawValue: UserDefaults.standard.string(forKey: Self.spokenLanguageKey) ?? ""
    ) ?? .automatic
    rememberedVoiceNames =
      (try? KeychainStore.read(service: Self.realtimeKeychainService, account: Self.voiceNamesAccount))
      .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
    restorePersistedAIProviders()
  }
}

/// The service choices being saved, apart from their keys.
struct AIProviderDraft: Equatable, Sendable {
  let speechEngine: SpeechEngine
  let speechBaseURL: String
  let speechModel: String
  let languageModelEngine: LanguageModelEngine
  let languageModelBaseURL: String
  let languageModelName: String
}

enum KeychainStore {
  static func save(_ value: String, service: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(value.utf8)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = query
      insertion[kSecValueData as String] = data
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let insertStatus = SecItemAdd(insertion as CFDictionary, nil)
      guard insertStatus == errSecSuccess else { throw KeychainError.status(insertStatus) }
    } else if status != errSecSuccess {
      throw KeychainError.status(status)
    }
  }

  static func read(service: String, account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError.status(status)
    }
    return String(data: data, encoding: .utf8)
  }

  static func delete(service: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }
}

enum KeychainError: Error {
  case status(OSStatus)
}
