import CryptoKit
import Foundation
import Network
import OSLog

/// Connecting this iPhone to a Mac (docs/sync-protocol.md, 配对): Macs nearby that show a code,
/// and the Mac's QR code, scanned in the app or with the Camera app. Nothing is saved until the
/// Mac answered with the new key (`MacUploader.confirm`).
@MainActor
@Observable
final class MacPairingFlow {
  struct NearbyMac: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let endpoint: NWEndpoint
  }

  /// A code the Mac is showing, and where to send it.
  struct CodeRequest: Equatable {
    let requestID: String
    let macName: String
    let host: NWEndpoint.Host
    let port: UInt16
    var attemptsLeft = SyncProtocol.codeAttempts
  }

  enum Method: Equatable { case code, qr }

  enum Failure: Equatable {
    case localNetwork
    case notFound
    case expired
    case message(String)
  }

  enum Stage: Equatable {
    case choose
    case requesting(NearbyMac)
    case enterCode(NearbyMac, CodeRequest)
    case confirmQR(SyncProtocol.Pairing)
    case connecting(macName: String, method: Method, step: Int)
    case done(macName: String)
    case failed(Failure)
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue", category: "MacPairing")

  weak var uploader: MacUploader?
  var presented = false
  private(set) var stage = Stage.choose
  private(set) var nearby: [NearbyMac] = []
  private(set) var localNetworkDenied = false
  /// Shown under the code boxes after a wrong code.
  private(set) var codeError: String?
  /// The typed code is being tried.
  private(set) var checkingCode = false
  @ObservationIgnored private var browser: NWBrowser?

  // MARK: Showing

  /// 连接 Mac: the list of nearby Macs and the scanner.
  func open() {
    stage = .choose
    codeError = nil
    presented = true
  }

  /// A pairing QR code, from the in-app scanner or the Camera app.
  func offer(_ code: SyncProtocol.Pairing) {
    stage = code.expires > .now ? .confirmQR(code) : .failed(.expired)
    presented = true
  }

  func backToList() {
    stage = .choose
    codeError = nil
  }

  func dismissed() {
    stopBrowsing()
    stage = .choose
  }

  // MARK: Nearby Macs

  func startBrowsing() {
    guard browser == nil else { return }
    let parameters = NWParameters()
    parameters.includePeerToPeer = false
    let browser = NWBrowser(for: .bonjour(type: SyncProtocol.pairServiceType, domain: nil), using: parameters)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let macs = results.compactMap { result -> NearbyMac? in
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        return NearbyMac(name: name, endpoint: result.endpoint)
      }.sorted { $0.name < $1.name }
      Task { @MainActor in self?.nearby = macs }
    }
    browser.stateUpdateHandler = { [weak self] state in
      var denied = false
      switch state {
      case .waiting(let error), .failed(let error):
        if case .dns(let code) = error, code == -65570 { denied = true }
      default: break
      }
      Task { @MainActor in
        if denied { self?.localNetworkDenied = true }
        if case .ready = state { self?.localNetworkDenied = false }
      }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stopBrowsing() {
    browser?.cancel()
    browser = nil
    nearby = []
  }

  // MARK: Pairing with a code

  /// Asks a nearby Mac to show a code.
  func request(_ mac: NearbyMac) {
    stage = .requesting(mac)
    codeError = nil
    Task {
      let parameters = SyncProtocol.parameters(keys: [(SyncProtocol.pairRequestIdentity, SyncProtocol.pairRequestKey)])
      let outcome = await MacUploader.open(mac.endpoint, using: parameters, timeout: 30)
      guard case .ready(let connection) = outcome else { return fail(outcome) }
      defer { connection.cancel() }
      let channel = SyncChannel(connection)
      let requestID = UUID().uuidString.lowercased()
      do {
        try await channel.send(.pairRequest(requestID: requestID, deviceName: MacUploader.deviceName))
        switch try await channel.receive().0 {
        case .pairPending(let macName, _, let port):
          guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else { return fail(.unreachable) }
          stage = .enterCode(mac, CodeRequest(requestID: requestID, macName: macName, host: host, port: port))
        case .failure(_, let reason, _):
          stage = .failed(.message(reason))
        default:
          stage = .failed(.message(AppLanguage.localized("The Mac sent an unexpected reply.")))
        }
      } catch {
        Self.logger.error("Pair request failed: \(String(describing: error), privacy: .public)")
        stage = .failed(.notFound)
      }
    }
  }

  /// The six digits typed on this iPhone. A wrong code fails the TLS handshake; the right one
  /// opens a channel in which both sides agree on the long-term key.
  func submit(code: String, for mac: NearbyMac, request: CodeRequest) {
    codeError = nil
    checkingCode = true
    Task {
      defer { checkingCode = false }
      let key = SyncProtocol.codeKey(code: code, requestID: request.requestID)
      let parameters = SyncProtocol.parameters(keys: [(SyncProtocol.codeIdentity(requestID: request.requestID), key)])
      guard let port = NWEndpoint.Port(rawValue: request.port) else { return }
      let outcome = await MacUploader.open(.hostPort(host: request.host, port: port), using: parameters, timeout: 10)
      switch outcome {
      case .ready(let connection):
        defer { connection.cancel() }
        await exchange(over: SyncChannel(connection), mac: mac, request: request)
      case .refused:
        var request = request
        request.attemptsLeft -= 1
        if request.attemptsLeft > 0 {
          stage = .enterCode(mac, request)
          codeError = String(format: AppLanguage.localized("Wrong code. %lld tries left."), request.attemptsLeft)
        } else {
          stage = .failed(.expired)
        }
      case .denied: stage = .failed(.localNetwork)
      // The Mac closed the code: it expired, was turned down, or had too many wrong tries.
      case .unreachable: stage = .failed(.expired)
      }
    }
  }

  private func exchange(over channel: SyncChannel, mac: NearbyMac, request: CodeRequest) async {
    stage = .connecting(macName: request.macName, method: .code, step: 1)
    let ours = Curve25519.KeyAgreement.PrivateKey()
    do {
      try await channel.send(.pairExchange(publicKey: ours.publicKey.rawRepresentation))
      guard case .pairAccepted(let macID, let macName, let service, let identity, let publicKey, let port) = try await channel.receive().0
      else { throw MacUploader.MacLinkError.unexpected }
      let secret = try ours.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
      let candidate = MacPairing(
        macID: macID, macName: macName, service: service, host: Self.text(request.host), port: port, identity: identity,
        key: SyncProtocol.pairingKey(secret, requestID: request.requestID), pairedAt: .now)
      stage = .connecting(macName: macName, method: .code, step: 2)
      try await finish(candidate)
    } catch {
      fail(error)
    }
  }

  // MARK: Pairing with the QR code

  func confirm(_ code: SyncProtocol.Pairing) {
    guard code.expires > .now, let key = Data(base64URL: code.key) else {
      stage = .failed(.expired)
      return
    }
    stage = .connecting(macName: code.macName, method: .qr, step: 1)
    let candidate = MacPairing(
      macID: code.macID, macName: code.macName, service: code.service, host: code.host, port: code.port,
      identity: code.identity, key: key, pairedAt: .now)
    Task {
      do {
        try await finish(candidate)
      } catch {
        fail(error)
      }
    }
  }

  // MARK: Finishing

  private func finish(_ candidate: MacPairing) async throws {
    guard let uploader else { return }
    try await uploader.confirm(candidate)
    stage = .done(macName: uploader.pairing?.macName ?? candidate.macName)
  }

  private func fail(_ outcome: MacUploader.Outcome) {
    switch outcome {
    case .denied: stage = .failed(.localNetwork)
    case .refused: stage = .failed(.message(AppLanguage.localized("Update WakeOnCue on the Mac, or use its QR code.")))
    default: stage = .failed(.notFound)
    }
  }

  private func fail(_ error: Error) {
    Self.logger.error("Pairing failed: \(String(describing: error), privacy: .public)")
    switch error {
    case MacUploader.MacLinkError.localNetworkDenied: stage = .failed(.localNetwork)
    case MacUploader.MacLinkError.notFound: stage = .failed(.notFound)
    // The QR code was used, expired, or replaced by a newer one on the Mac.
    case MacUploader.MacLinkError.refusedKey: stage = .failed(.expired)
    case MacUploader.MacLinkError.refused(let reason): stage = .failed(.message(reason))
    default: stage = .failed(.message(error.localizedDescription))
    }
  }

  private static func text(_ host: NWEndpoint.Host) -> String {
    switch host {
    case .name(let name, _): name
    case .ipv4(let address): "\(address)"
    case .ipv6(let address): "\(address)"
    @unknown default: ""
    }
  }
}
