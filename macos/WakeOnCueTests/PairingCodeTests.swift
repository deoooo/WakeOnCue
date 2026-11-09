import CryptoKit
import Foundation
import Network
import XCTest

/// Pairing with a code: the keys both sides derive, the new messages, and a real TLS handshake
/// on loopback that takes the right code and refuses a wrong one.
nonisolated final class PairingCodeTests: XCTestCase {
  func testCodesAreSixDigits() {
    for _ in 0..<200 {
      let code = SyncProtocol.newCode()
      XCTAssertEqual(code.count, 6)
      XCTAssertTrue(code.allSatisfy(\.isNumber))
    }
  }

  func testCodeKeyDependsOnCodeAndRequest() {
    let key = SyncProtocol.codeKey(code: "482913", requestID: "a")
    XCTAssertEqual(key.count, 32)
    XCTAssertEqual(key, SyncProtocol.codeKey(code: "482913", requestID: "a"))
    XCTAssertNotEqual(key, SyncProtocol.codeKey(code: "482914", requestID: "a"))
    XCTAssertNotEqual(key, SyncProtocol.codeKey(code: "482913", requestID: "b"))
  }

  func testBothSidesDeriveTheSamePairingKey() throws {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let onPhone = SyncProtocol.pairingKey(try phone.sharedSecretFromKeyAgreement(with: mac.publicKey), requestID: "r")
    let onMac = SyncProtocol.pairingKey(try mac.sharedSecretFromKeyAgreement(with: phone.publicKey), requestID: "r")
    XCTAssertEqual(onPhone, onMac)
    XCTAssertEqual(onPhone.count, 32)
  }

  func testPairMessagesRoundTrip() throws {
    let messages: [SyncProtocol.Message] = [
      .pairRequest(requestID: "r1", deviceName: "Deo 的 iPhone"),
      .pairPending(macName: "Mac", expires: Date(timeIntervalSince1970: 1_800_000_000), port: 50123),
      .pairExchange(publicKey: Data([1, 2, 3])),
      .pairAccepted(macID: "m", macName: "Mac", service: "Mac", identity: "phone-1", publicKey: Data([4, 5]), port: 50000),
    ]
    for message in messages {
      let frame = try SyncProtocol.frame(message)
      XCTAssertEqual(try SyncProtocol.decodeHeader(frame.dropFirst(4)), message)
    }
  }

  func testHandshakeTakesOnlyTheRightCode() async throws {
    let requestID = "loopback"
    let identity = SyncProtocol.codeIdentity(requestID: requestID)
    let server = SyncProtocol.parameters(keys: [(identity, SyncProtocol.codeKey(code: "123456", requestID: requestID))])
    let listener = try NWListener(using: server, on: .any)
    listener.newConnectionHandler = { $0.start(queue: .global()) }
    let port: NWEndpoint.Port = await withCheckedContinuation { continuation in
      listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port { continuation.resume(returning: port) }
      }
      listener.start(queue: .global())
    }
    defer { listener.cancel() }

    let right = await handshake(port: port, keys: [(identity, SyncProtocol.codeKey(code: "123456", requestID: requestID))])
    XCTAssertEqual(right, "ready")
    let wrong = await handshake(port: port, keys: [(identity, SyncProtocol.codeKey(code: "123457", requestID: requestID))])
    XCTAssertEqual(wrong, "refused")
  }

  private func handshake(port: NWEndpoint.Port, keys: [(identity: String, key: Data)]) async -> String {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: SyncProtocol.parameters(keys: keys))
    defer { connection.cancel() }
    return await withCheckedContinuation { continuation in
      let once = Once(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: once.finish("ready")
        case .failed: once.finish("refused")
        case .waiting(let error): if case .tls = error { once.finish("refused") } else { once.last = "waiting \(error)" }
        default: break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.finish("timeout " + once.last) }
    }
  }
}

nonisolated private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Never>?
  var last = ""

  init(_ continuation: CheckedContinuation<String, Never>) {
    self.continuation = continuation
  }

  func finish(_ result: String) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }
}
