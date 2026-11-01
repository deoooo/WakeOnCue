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
  private static let endpointKey = "recording-storage.s3.endpoint"
  private static let regionKey = "recording-storage.s3.region"
  private static let bucketKey = "recording-storage.s3.bucket"
  private static let prefixKey = "recording-storage.s3.prefix"
  private static let forcePathStyleKey = "recording-storage.s3.force-path-style"
  private static let keychainService = "com.deoooo.WakeOnCue.s3"
  private static let accessKeyAccount = "access-key-id"
  private static let secretKeyAccount = "secret-access-key"
  private static let sessionTokenAccount = "session-token"
  private static let realtimeEnabledKey = "realtime-processing.enabled"
  private static let realtimeGatewayURLKey = "realtime-processing.gateway-url"
  static let spokenLanguageKey = "realtime-processing.spoken-language"
  private static let realtimeKeychainService = "com.deoooo.WakeOnCue.realtime"
  private static let realtimeTokenAccount = "gateway-token"
  private static let selfVoiceprintAccount = "self-voiceprint"
  private static let savedVoicesAccount = "saved-voices"
  private static let speakerDiarizationKey = "speakers.diarization-enabled"
  private static let rememberVoicesKey = "speakers.remember-voices"
  private static let aiKeychainService = "com.deoooo.WakeOnCue.ai"
  private static let speechKeyAccount = "speech-api-key"
  private static let languageModelKeyAccount = "language-model-api-key"
  private static let speechEngineKey = "ai.speech.engine"
  private static let speechBaseURLKey = "ai.speech.base-url"
  private static let speechModelKey = "ai.speech.model"
  private static let languageModelEngineKey = "ai.language-model.engine"
  private static let languageModelBaseURLKey = "ai.language-model.base-url"
  private static let languageModelNameKey = "ai.language-model.model"
  /// Saved voices not heard in a recording for this long are deleted.
  static let savedVoiceExpiry: TimeInterval = 365 * 24 * 60 * 60

  var useRealtimeProcessing = false
  var realtimeGatewayURL = ""
  var realtimeGatewayToken = ""
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
  /// S3 credentials saved by an older version, kept to reach recordings already backed up.
  private(set) var hasLegacyS3Credentials = false
  private(set) var realtimeHasStoredToken = false
  /// When the device owner enrolled their voice; nil when no voiceprint is stored.
  private(set) var selfVoiceprintEnrolledAt: Date?
  /// Voices of people the user named, kept only while "Remember voices" is on.
  private(set) var savedVoices: [SavedVoice] = []
  /// Off by default; recordings are only split by speaker after the user turns it on.
  var speakerDiarizationEnabled = false {
    didSet { UserDefaults.standard.set(speakerDiarizationEnabled, forKey: Self.speakerDiarizationKey) }
  }
  private(set) var rememberVoicesEnabled = false

  init() {
    language = AppLanguage.current
    if let rawAppearance = UserDefaults.standard.string(forKey: AppAppearance.preferenceKey),
      let storedAppearance = AppAppearance(rawValue: rawAppearance)
    {
      appearance = storedAppearance
    }
    restorePersistedSettings()
    #if DEBUG
      if let configuration = Self.debugRealtimeConfiguration {
        useRealtimeProcessing = true
        realtimeGatewayURL = configuration.gatewayURL.absoluteString
        realtimeHasStoredToken = true
      }
    #endif
  }

  var activeRealtimeConfiguration: RealtimeProcessingConfiguration? {
    #if DEBUG
      if var configuration = Self.debugRealtimeConfiguration {
        applySpeakerOptions(to: &configuration)
        return configuration
      }
    #endif
    guard UserDefaults.standard.bool(forKey: Self.realtimeEnabledKey) else { return nil }
    return persistedRealtimeConfiguration()
  }

  /// The Gateway to send a voice enrollment sample to: the saved one, or the one being edited.
  func voiceEnrollmentConfiguration() throws -> RealtimeProcessingConfiguration {
    if let configuration = activeRealtimeConfiguration { return configuration }
    return try candidateRealtimeConfiguration()
  }

  /// Stored only in this device's Keychain: excluded from backups and iCloud.
  func persistSelfVoiceprint(_ voiceprint: RealtimeVoiceprint, enrolledAt: Date = .now) throws {
    let record = SelfVoiceprintRecord(voiceprint: voiceprint, enrolledAt: enrolledAt)
    let data = try JSONEncoder().encode(record)
    try KeychainStore.save(
      String(decoding: data, as: UTF8.self),
      service: Self.realtimeKeychainService,
      account: Self.selfVoiceprintAccount
    )
    selfVoiceprintEnrolledAt = enrolledAt
  }

  func deleteSelfVoiceprint() throws {
    try KeychainStore.delete(
      service: Self.realtimeKeychainService, account: Self.selfVoiceprintAccount)
    selfVoiceprintEnrolledAt = nil
  }

  /// Names shown for person IDs the processor recognized, including the user.
  var personNames: [String: String] {
    var names = Dictionary(uniqueKeysWithValues: savedVoices.map { ($0.id, $0.name) })
    names[RealtimeSpeaker.selfPersonID] = AppLanguage.localized("Me")
    return names
  }

  func setRememberVoices(_ enabled: Bool) throws {
    if !enabled { try deleteAllSavedVoices() }
    rememberVoicesEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.rememberVoicesKey)
  }

  func saveVoice(name: String, voiceprint: RealtimeVoiceprint, replacing id: String? = nil) throws {
    let now = Date.now
    var voices = savedVoices.filter { $0.id != id }
    voices.append(
      SavedVoice(
        id: id ?? UUID().uuidString, name: name, voiceprint: voiceprint,
        createdAt: now, lastHeardAt: now))
    try persistSavedVoices(voices)
  }

  func renameSavedVoice(id: String, to name: String) throws {
    try persistSavedVoices(savedVoices.map { $0.id == id ? $0.renamed(name) : $0 })
  }

  func deleteSavedVoice(id: String) throws {
    try persistSavedVoices(savedVoices.filter { $0.id != id })
  }

  func deleteAllSavedVoices() throws {
    try KeychainStore.delete(service: Self.realtimeKeychainService, account: Self.savedVoicesAccount)
    savedVoices = []
  }

  /// Records that saved voices were recognized, so they do not expire.
  func markVoicesHeard(_ ids: Set<String>, at date: Date = .now) {
    guard
      savedVoices.contains(where: {
        ids.contains($0.id) && date.timeIntervalSince($0.lastHeardAt) > 86_400
      })
    else { return }
    try? persistSavedVoices(savedVoices.map { ids.contains($0.id) ? $0.heard(at: date) : $0 })
  }

  private func persistSavedVoices(_ voices: [SavedVoice]) throws {
    if voices.isEmpty {
      try deleteAllSavedVoices()
      return
    }
    let data = try JSONEncoder().encode(voices)
    try KeychainStore.save(
      String(decoding: data, as: UTF8.self),
      service: Self.realtimeKeychainService,
      account: Self.savedVoicesAccount
    )
    savedVoices = voices
  }

  private func restoreSpeakerSettings() {
    let defaults = UserDefaults.standard
    speakerDiarizationEnabled = defaults.bool(forKey: Self.speakerDiarizationKey)
    rememberVoicesEnabled = defaults.bool(forKey: Self.rememberVoicesKey)
    selfVoiceprintEnrolledAt = storedSelfVoiceprint()?.enrolledAt
    let stored =
      (try? KeychainStore.read(
        service: Self.realtimeKeychainService, account: Self.savedVoicesAccount))
      .flatMap { try? JSONDecoder().decode([SavedVoice].self, from: Data($0.utf8)) } ?? []
    let cutoff = Date.now.addingTimeInterval(-Self.savedVoiceExpiry)
    let current = stored.filter { $0.lastHeardAt >= cutoff }
    savedVoices = current
    if current.count != stored.count { try? persistSavedVoices(current) }
  }

  private func applySpeakerOptions(to configuration: inout RealtimeProcessingConfiguration) {
    guard speakerDiarizationEnabled else { return }
    configuration.speakerDiarization = true
    var voices: [RealtimeKnownVoiceprint] = []
    if let own = storedSelfVoiceprint()?.voiceprint {
      voices.append(
        RealtimeKnownVoiceprint(personID: RealtimeSpeaker.selfPersonID, voiceprint: own))
    }
    if rememberVoicesEnabled {
      voices += savedVoices.map {
        RealtimeKnownVoiceprint(personID: $0.id, voiceprint: $0.voiceprint)
      }
    }
    configuration.knownVoiceprints = voices
  }

  private func storedSelfVoiceprint() -> SelfVoiceprintRecord? {
    guard
      let stored = try? KeychainStore.read(
        service: Self.realtimeKeychainService, account: Self.selfVoiceprintAccount)
    else { return nil }
    return try? JSONDecoder().decode(SelfVoiceprintRecord.self, from: Data(stored.utf8))
  }

  #if DEBUG
    private static var debugRealtimeConfiguration: RealtimeProcessingConfiguration? {
      let environment = ProcessInfo.processInfo.environment
      guard
        let rawURL = environment["WAKEONCUE_TEST_REALTIME_GATEWAY_URL"],
        let gatewayURL = URL(string: rawURL),
        let bearerToken = environment["WAKEONCUE_TEST_REALTIME_GATEWAY_TOKEN"],
        !bearerToken.isEmpty
      else { return nil }
      return RealtimeProcessingConfiguration(
        gatewayURL: gatewayURL,
        bearerToken: bearerToken
      )
    }
  #endif

  /// The endpoint being edited, or nil when Apple's on-device speech is selected. A blank key
  /// keeps the stored one only for the same URL, so it is never sent to a different service.
  func candidateSpeechEndpoint() throws -> ThirdPartyEndpoint? {
    guard let defaultURL = speechEngine.defaultBaseURL else { return nil }
    let baseURL = speechBaseURL.isEmpty ? defaultURL : speechBaseURL
    let isUnchanged = activeSpeechEndpoint?.baseURL.absoluteString == baseURL
    return try ThirdPartyEndpoint.validated(
      baseURL: baseURL,
      model: speechModel,
      apiKey: speechAPIKey.isEmpty && isUnchanged
        ? (activeSpeechEndpoint?.apiKey ?? "") : speechAPIKey
    )
  }

  func candidateLanguageModelProvider() throws -> LanguageModelProvider? {
    guard let defaultURL = languageModelEngine.defaultBaseURL else { return nil }
    let wireProtocol: LanguageModelProvider.WireProtocol =
      languageModelEngine == .anthropic ? .anthropic : .openAI
    let baseURL = languageModelBaseURL.isEmpty ? defaultURL : languageModelBaseURL
    let isUnchanged =
      activeLanguageModelProvider?.wireProtocol == wireProtocol
      && activeLanguageModelProvider?.endpoint.baseURL.absoluteString == baseURL
    return LanguageModelProvider(
      wireProtocol: wireProtocol,
      endpoint: try ThirdPartyEndpoint.validated(
        baseURL: baseURL,
        model: languageModelName,
        apiKey: languageModelAPIKey.isEmpty && isUnchanged
          ? (activeLanguageModelProvider?.endpoint.apiKey ?? "") : languageModelAPIKey
      )
    )
  }

  /// Keys are deleted as soon as a service is turned off.
  func persistAIProviders(
    speech: ThirdPartyEndpoint?, languageModel: LanguageModelProvider?
  ) throws {
    try KeychainStore.save(
      speech?.apiKey ?? "", service: Self.aiKeychainService, account: Self.speechKeyAccount)
    try KeychainStore.save(
      languageModel?.endpoint.apiKey ?? "",
      service: Self.aiKeychainService,
      account: Self.languageModelKeyAccount
    )
    let defaults = UserDefaults.standard
    defaults.set(speechEngine.rawValue, forKey: Self.speechEngineKey)
    defaults.set(speechBaseURL, forKey: Self.speechBaseURLKey)
    defaults.set(speechModel, forKey: Self.speechModelKey)
    defaults.set(languageModelEngine.rawValue, forKey: Self.languageModelEngineKey)
    defaults.set(languageModelBaseURL, forKey: Self.languageModelBaseURLKey)
    defaults.set(languageModelName, forKey: Self.languageModelNameKey)
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

  func candidateRealtimeConfiguration() throws -> RealtimeProcessingConfiguration {
    let trimmedURL = realtimeGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL), let scheme = url.scheme,
      ["http", "https"].contains(scheme), url.host != nil
    else {
      throw RealtimeSettingsError.invalid(
        language.localized("Enter a valid HTTP(S) realtime Gateway URL."))
    }
    let token =
      realtimeGatewayToken.isEmpty
      ? (try KeychainStore.read(
        service: Self.realtimeKeychainService, account: Self.realtimeTokenAccount) ?? "")
      : realtimeGatewayToken
    guard !token.isEmpty else {
      throw RealtimeSettingsError.invalid(language.localized("Gateway token is required."))
    }
    return RealtimeProcessingConfiguration(gatewayURL: url, bearerToken: token)
  }

  func applyRealtimePairing(_ pairing: RealtimeServicePairing) {
    useRealtimeProcessing = true
    realtimeGatewayURL = pairing.gatewayURL.absoluteString
    realtimeGatewayToken = pairing.gatewayToken
  }

  func persistRealtimeConfiguration(_ configuration: RealtimeProcessingConfiguration) throws {
    try KeychainStore.save(
      configuration.bearerToken,
      service: Self.realtimeKeychainService,
      account: Self.realtimeTokenAccount
    )
    let defaults = UserDefaults.standard
    defaults.set(configuration.gatewayURL.absoluteString, forKey: Self.realtimeGatewayURLKey)
    defaults.set(true, forKey: Self.realtimeEnabledKey)
  }

  func restorePersistedSettings() {
    hasLegacyS3Credentials = storedCredentials() != nil
    restorePersistedRealtimeConfiguration()
    restorePersistedAIProviders()
  }

  func persistRealtimeDisabled() {
    UserDefaults.standard.set(false, forKey: Self.realtimeEnabledKey)
    restorePersistedRealtimeConfiguration()
  }

  private func restorePersistedRealtimeConfiguration() {
    let defaults = UserDefaults.standard
    let token = try? KeychainStore.read(
      service: Self.realtimeKeychainService, account: Self.realtimeTokenAccount)
    realtimeHasStoredToken = token?.isEmpty == false
    useRealtimeProcessing = defaults.bool(forKey: Self.realtimeEnabledKey) && realtimeHasStoredToken
    if defaults.bool(forKey: Self.realtimeEnabledKey), !realtimeHasStoredToken {
      defaults.set(false, forKey: Self.realtimeEnabledKey)
    }
    realtimeGatewayURL = defaults.string(forKey: Self.realtimeGatewayURLKey) ?? ""
    realtimeGatewayToken = ""
    restoreSpeakerSettings()
    spokenLanguage = SpokenLanguage(
      rawValue: defaults.string(forKey: Self.spokenLanguageKey) ?? ""
    ) ?? .automatic
  }

  private func persistedRealtimeConfiguration() -> RealtimeProcessingConfiguration? {
    let defaults = UserDefaults.standard
    guard let url = URL(string: defaults.string(forKey: Self.realtimeGatewayURLKey) ?? ""),
      let token = try? KeychainStore.read(
        service: Self.realtimeKeychainService, account: Self.realtimeTokenAccount),
      !token.isEmpty
    else { return nil }
    var configuration = RealtimeProcessingConfiguration(gatewayURL: url, bearerToken: token)
    applySpeakerOptions(to: &configuration)
    return configuration
  }

  var legacyS3Configuration: S3Configuration? {
    let defaults = UserDefaults.standard
    guard let credentials = storedCredentials() else { return nil }
    let endpoint = (defaults.string(forKey: Self.endpointKey)).flatMap { URL(string: $0) }
    return S3Configuration(
      endpointURL: endpoint?.host == nil ? nil : endpoint,
      region: defaults.string(forKey: Self.regionKey) ?? "us-east-1",
      bucket: defaults.string(forKey: Self.bucketKey) ?? "",
      prefix: defaults.string(forKey: Self.prefixKey) ?? "wakeoncue",
      accessKeyID: credentials.accessKey,
      secretAccessKey: credentials.secretKey,
      sessionToken: credentials.sessionToken,
      forcePathStyle: defaults.bool(forKey: Self.forcePathStyleKey)
    )
  }

  func forgetLegacyS3Storage() throws {
    for account in [Self.accessKeyAccount, Self.secretKeyAccount, Self.sessionTokenAccount] {
      try KeychainStore.delete(service: Self.keychainService, account: account)
    }
    hasLegacyS3Credentials = false
  }

  private func storedCredentials() -> (accessKey: String, secretKey: String, sessionToken: String?)?
  {
    guard
      let accessKey = try? KeychainStore.read(
        service: Self.keychainService, account: Self.accessKeyAccount),
      !accessKey.isEmpty,
      let secretKey = try? KeychainStore.read(
        service: Self.keychainService, account: Self.secretKeyAccount),
      !secretKey.isEmpty
    else { return nil }
    let token = try? KeychainStore.read(
      service: Self.keychainService, account: Self.sessionTokenAccount)
    return (accessKey, secretKey, token?.isEmpty == false ? token : nil)
  }
}

struct RealtimeProcessingConfiguration: Equatable, Sendable {
  let gatewayURL: URL
  let bearerToken: String
  var speakerDiarization = false
  var knownVoiceprints: [RealtimeKnownVoiceprint] = []
}

/// A named person's voiceprint. It never leaves this device except to the user's own
/// realtime service for the length of a session.
struct SavedVoice: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let voiceprint: RealtimeVoiceprint
  let createdAt: Date
  let lastHeardAt: Date

  func renamed(_ name: String) -> SavedVoice {
    SavedVoice(
      id: id, name: name, voiceprint: voiceprint, createdAt: createdAt, lastHeardAt: lastHeardAt)
  }

  func heard(at date: Date) -> SavedVoice {
    SavedVoice(id: id, name: name, voiceprint: voiceprint, createdAt: createdAt, lastHeardAt: date)
  }
}

private struct SelfVoiceprintRecord: Codable {
  let voiceprint: RealtimeVoiceprint
  let enrolledAt: Date
}

enum RealtimeSettingsError: LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
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
