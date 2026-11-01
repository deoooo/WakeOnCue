import Foundation

struct RealtimeServicePairing: Codable, Equatable, Sendable {
  static let currentVersion = 1
  static let payloadType = "wakeoncue.realtime-gateway"

  let type: String
  let version: Int
  let gatewayURL: URL
  let gatewayToken: String

  init(gatewayURL: URL, gatewayToken: String) throws {
    try Self.validate(url: gatewayURL, token: gatewayToken)
    self.type = Self.payloadType
    self.version = Self.currentVersion
    self.gatewayURL = gatewayURL
    self.gatewayToken = gatewayToken
  }

  init(payload: String) throws {
    guard let data = payload.data(using: .utf8) else {
      throw RealtimePairingError.malformedPayload
    }
    do {
      self = try JSONDecoder().decode(Self.self, from: data)
    } catch let error as RealtimePairingError {
      throw error
    } catch {
      throw RealtimePairingError.malformedPayload
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    let version = try container.decode(Int.self, forKey: .version)
    let rawURL = try container.decode(String.self, forKey: .gatewayURL)
    let token = try container.decode(String.self, forKey: .gatewayToken)

    guard type == Self.payloadType else { throw RealtimePairingError.unsupportedType }
    guard version == Self.currentVersion else {
      throw RealtimePairingError.unsupportedVersion(version)
    }
    guard let url = URL(string: rawURL) else { throw RealtimePairingError.invalidURL }
    try Self.validate(url: url, token: token)

    self.type = type
    self.version = version
    self.gatewayURL = url
    self.gatewayToken = token
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(version, forKey: .version)
    try container.encode(gatewayURL.absoluteString, forKey: .gatewayURL)
    try container.encode(gatewayToken, forKey: .gatewayToken)
  }

  private static func validate(url: URL, token: String) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { throw RealtimePairingError.invalidURL }
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RealtimePairingError.missingToken
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case version
    case gatewayURL = "gateway_url"
    case gatewayToken = "gateway_token"
  }
}

enum RealtimePairingError: Error, LocalizedError, Equatable {
  case malformedPayload
  case unsupportedType
  case unsupportedVersion(Int)
  case invalidURL
  case missingToken

  var errorDescription: String? {
    switch self {
    case .malformedPayload:
      AppLanguage.localized("The pairing code is not valid WakeOnCue JSON.")
    case .unsupportedType:
      AppLanguage.localized("This pairing code is for a different service.")
    case .unsupportedVersion(let version):
      String(
        format: AppLanguage.localized("Pairing version %d is not supported."),
        locale: AppLanguage.current.locale,
        version
      )
    case .invalidURL:
      AppLanguage.localized("The pairing code must contain a valid HTTP(S) Gateway URL.")
    case .missingToken:
      AppLanguage.localized("The pairing code does not contain a Gateway token.")
    }
  }
}
