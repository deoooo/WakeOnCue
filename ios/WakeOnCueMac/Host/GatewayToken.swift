import Foundation
import Security

/// The long-lived Gateway bearer token, stored in the login Keychain under the same item
/// `server/scripts/setup_mac.sh` uses. Reading goes through `/usr/bin/security` because the
/// item is created by that tool and its access list already trusts it, so no prompt appears.
enum GatewayToken {
  static let service = "com.deoooo.WakeOnCue.realtime.mac"
  static let account = "gateway-token"

  static func load() -> String? {
    let output = try? run(["find-generic-password", "-s", service, "-a", account, "-w"])
    let token = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return token.isEmpty ? nil : token
  }

  /// Returns the existing token, or creates a random one the way `setup_mac.sh` does.
  static func loadOrCreate() throws -> String {
    if let token = load() { return token }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw GatewayTokenError.randomUnavailable
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    _ = try run(["add-generic-password", "-U", "-s", service, "-a", account, "-w", token])
    guard load() == token else { throw GatewayTokenError.keychainWriteFailed }
    return token
  }

  private static func run(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GatewayTokenError.keychainWriteFailed }
    return String(decoding: data, as: UTF8.self)
  }
}

enum GatewayTokenError: Error, LocalizedError {
  case randomUnavailable
  case keychainWriteFailed

  var errorDescription: String? {
    switch self {
    case .randomUnavailable: String(localized: "Could not create a random Gateway token.")
    case .keychainWriteFailed: String(localized: "Could not save the Gateway token in the Keychain.")
    }
  }
}
