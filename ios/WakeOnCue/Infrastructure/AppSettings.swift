import Foundation
import Observation
import Security
import WakeOnCueCore

@MainActor
@Observable
final class AppSettings {
  static let defaultLocalAudioRetentionDays = 7
  static let localAudioRetentionDaysRange = 1...365

  private static let s3EnabledKey = "recording-storage.s3-enabled"
  private static let endpointKey = "recording-storage.s3.endpoint"
  private static let regionKey = "recording-storage.s3.region"
  private static let bucketKey = "recording-storage.s3.bucket"
  private static let prefixKey = "recording-storage.s3.prefix"
  private static let forcePathStyleKey = "recording-storage.s3.force-path-style"
  private static let localAudioRetentionDaysKey = "recording-storage.local-audio-retention-days"
  private static let keychainService = "com.deoooo.WakeOnCue.s3"
  private static let accessKeyAccount = "access-key-id"
  private static let secretKeyAccount = "secret-access-key"
  private static let sessionTokenAccount = "session-token"
  private static let realtimeEnabledKey = "realtime-processing.enabled"
  private static let realtimeGatewayURLKey = "realtime-processing.gateway-url"
  static let spokenLanguageKey = "realtime-processing.spoken-language"
  private static let realtimeKeychainService = "com.deoooo.WakeOnCue.realtime"
  private static let realtimeTokenAccount = "gateway-token"

  var useS3 = false
  var s3EndpointURL = ""
  var s3Region = "us-east-1"
  var s3Bucket = ""
  var s3Prefix = "wakeoncue"
  var s3AccessKeyID = ""
  var s3SecretAccessKey = ""
  var s3SessionToken = ""
  var s3ForcePathStyle = false
  var localAudioRetentionDays = defaultLocalAudioRetentionDays
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
  private(set) var s3HasStoredCredentials = false
  private(set) var realtimeHasStoredToken = false

  init() {
    language = AppLanguage.current
    restorePersistedSettings()
    #if DEBUG
      if let configuration = Self.debugRealtimeConfiguration {
        useRealtimeProcessing = true
        realtimeGatewayURL = configuration.gatewayURL.absoluteString
        realtimeHasStoredToken = true
      }
    #endif
  }

  var activeS3Configuration: S3Configuration? {
    guard UserDefaults.standard.bool(forKey: Self.s3EnabledKey) else { return nil }
    return persistedS3Configuration()
  }

  var activeRealtimeConfiguration: RealtimeProcessingConfiguration? {
    #if DEBUG
      if let configuration = Self.debugRealtimeConfiguration { return configuration }
    #endif
    guard UserDefaults.standard.bool(forKey: Self.realtimeEnabledKey) else { return nil }
    return persistedRealtimeConfiguration()
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

  var activeLocalAudioRetention: TimeInterval {
    let stored = UserDefaults.standard.integer(forKey: Self.localAudioRetentionDaysKey)
    let days = stored == 0 ? Self.defaultLocalAudioRetentionDays : stored
    return Self.localAudioRetentionInterval(days: days)
  }

  static func normalizedLocalAudioRetentionDays(_ days: Int) -> Int {
    min(
      max(days, localAudioRetentionDaysRange.lowerBound),
      localAudioRetentionDaysRange.upperBound
    )
  }

  static func localAudioRetentionInterval(days: Int) -> TimeInterval {
    TimeInterval(normalizedLocalAudioRetentionDays(days) * 24 * 60 * 60)
  }

  func candidateS3Configuration() throws -> S3Configuration {
    let endpoint = try endpointURL(from: s3EndpointURL)
    let accessKey =
      s3AccessKeyID.isEmpty
      ? (try KeychainStore.read(service: Self.keychainService, account: Self.accessKeyAccount) ?? "")
      : s3AccessKeyID
    let secretKey =
      s3SecretAccessKey.isEmpty
      ? (try KeychainStore.read(service: Self.keychainService, account: Self.secretKeyAccount) ?? "")
      : s3SecretAccessKey
    let sessionToken =
      s3SessionToken.isEmpty
      ? try KeychainStore.read(service: Self.keychainService, account: Self.sessionTokenAccount)
      : s3SessionToken
    let bucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    let region = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bucket.isEmpty, !region.isEmpty else {
      throw S3SettingsError.invalid(language.localized("S3 bucket and region are required."))
    }
    guard !accessKey.isEmpty, !secretKey.isEmpty else {
      throw S3SettingsError.invalid(
        language.localized("S3 access key and secret key are required."))
    }
    return S3Configuration(
      endpointURL: endpoint,
      region: region,
      bucket: bucket,
      prefix: s3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: " /")),
      accessKeyID: accessKey,
      secretAccessKey: secretKey,
      sessionToken: sessionToken,
      forcePathStyle: s3ForcePathStyle
    )
  }

  func persistS3Configuration(
    _ configuration: S3Configuration,
    localAudioRetentionDays: Int
  ) throws {
    try KeychainStore.save(
      configuration.accessKeyID,
      service: Self.keychainService,
      account: Self.accessKeyAccount
    )
    try KeychainStore.save(
      configuration.secretAccessKey,
      service: Self.keychainService,
      account: Self.secretKeyAccount
    )
    try KeychainStore.save(
      configuration.sessionToken ?? "",
      service: Self.keychainService,
      account: Self.sessionTokenAccount
    )

    let defaults = UserDefaults.standard
    defaults.set(configuration.endpointURL?.absoluteString ?? "", forKey: Self.endpointKey)
    defaults.set(configuration.region, forKey: Self.regionKey)
    defaults.set(configuration.bucket, forKey: Self.bucketKey)
    defaults.set(configuration.prefix, forKey: Self.prefixKey)
    defaults.set(configuration.forcePathStyle, forKey: Self.forcePathStyleKey)
    defaults.set(
      Self.normalizedLocalAudioRetentionDays(localAudioRetentionDays),
      forKey: Self.localAudioRetentionDaysKey
    )
    defaults.set(true, forKey: Self.s3EnabledKey)
    restorePersistedStorageMode()
  }

  func persistLocalMode() {
    UserDefaults.standard.set(false, forKey: Self.s3EnabledKey)
    restorePersistedStorageMode()
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
    restorePersistedStorageMode()
    restorePersistedRealtimeConfiguration()
  }

  func persistRealtimeDisabled() {
    UserDefaults.standard.set(false, forKey: Self.realtimeEnabledKey)
    restorePersistedRealtimeConfiguration()
  }

  func restorePersistedStorageMode() {
    let defaults = UserDefaults.standard
    let credentials = storedCredentials()
    s3HasStoredCredentials = credentials != nil
    useS3 = defaults.bool(forKey: Self.s3EnabledKey) && credentials != nil
    if defaults.bool(forKey: Self.s3EnabledKey), credentials == nil {
      defaults.set(false, forKey: Self.s3EnabledKey)
    }
    s3EndpointURL = defaults.string(forKey: Self.endpointKey) ?? ""
    s3Region = defaults.string(forKey: Self.regionKey) ?? "us-east-1"
    s3Bucket = defaults.string(forKey: Self.bucketKey) ?? ""
    s3Prefix = defaults.string(forKey: Self.prefixKey) ?? "wakeoncue"
    s3ForcePathStyle = defaults.bool(forKey: Self.forcePathStyleKey)
    let storedRetentionDays = defaults.integer(forKey: Self.localAudioRetentionDaysKey)
    localAudioRetentionDays =
      storedRetentionDays == 0
      ? Self.defaultLocalAudioRetentionDays
      : Self.normalizedLocalAudioRetentionDays(storedRetentionDays)
    s3AccessKeyID = ""
    s3SecretAccessKey = ""
    s3SessionToken = ""
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
    return RealtimeProcessingConfiguration(gatewayURL: url, bearerToken: token)
  }

  private func persistedS3Configuration() -> S3Configuration? {
    let defaults = UserDefaults.standard
    guard let credentials = storedCredentials() else { return nil }
    let endpointString = defaults.string(forKey: Self.endpointKey) ?? ""
    return S3Configuration(
      endpointURL: try? endpointURL(from: endpointString),
      region: defaults.string(forKey: Self.regionKey) ?? "us-east-1",
      bucket: defaults.string(forKey: Self.bucketKey) ?? "",
      prefix: defaults.string(forKey: Self.prefixKey) ?? "wakeoncue",
      accessKeyID: credentials.accessKey,
      secretAccessKey: credentials.secretKey,
      sessionToken: credentials.sessionToken,
      forcePathStyle: defaults.bool(forKey: Self.forcePathStyleKey)
    )
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

  private func endpointURL(from value: String) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme,
      ["http", "https"].contains(scheme), url.host != nil
    else {
      throw S3SettingsError.invalid(language.localized("Enter a valid HTTP(S) S3 endpoint."))
    }
    return url
  }
}

struct RealtimeProcessingConfiguration: Equatable, Sendable {
  let gatewayURL: URL
  let bearerToken: String
}

enum RealtimeSettingsError: LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}

enum S3SettingsError: LocalizedError {
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
}

enum KeychainError: Error {
  case status(OSStatus)
}
