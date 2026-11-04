import Foundation
import Security

/// A phone allowed to send audio to this Mac.
nonisolated struct PairedDevice: Codable, Identifiable, Hashable, Sendable {
  /// The PSK identity, also the device's ID in the protocol.
  var id: String
  var name: String
  var key: Data
  var pairedAt: Date
  var lastSeen: Date?
}

/// Pairing keys in the login keychain: the paired phones and at most one open invitation (the
/// QR code currently shown), which is valid for five minutes and only once.
nonisolated enum PairingKeychain {
  private static let service = "com.deoooo.WakeOnCue.macos.pairing"

  private static func read<T: Decodable>(_ account: String, as type: T.Type) -> T? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder.sync.decode(type, from: data)
  }

  private static func write<T: Encodable>(_ value: T?, _ account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard let value, let data = try? JSONEncoder.sync.encode(value) else { return }
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "WakeOnCue 设备配对"
    SecItemAdd(attributes as CFDictionary, nil)
  }

  static var devices: [PairedDevice] {
    get { read("devices", as: [PairedDevice].self) ?? [] }
    set { write(newValue, "devices") }
  }

  /// The open invitation: identity, key and when it stops working.
  struct Invitation: Codable {
    var identity: String
    var key: Data
    var expires: Date
  }

  static var invitation: Invitation? {
    get { read("invitation", as: Invitation.self).flatMap { $0.expires > .now ? $0 : nil } }
    set { write(newValue, "invitation") }
  }

  /// This Mac's ID in pairing codes, made once.
  static var macID: String {
    if let id = read("mac-id", as: String.self) { return id }
    let id = UUID().uuidString.lowercased()
    write(id, "mac-id")
    return id
  }

  static func randomKey() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes)
  }
}
