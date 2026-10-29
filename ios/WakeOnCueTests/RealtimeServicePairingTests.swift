import Foundation
import XCTest

@testable import WakeOnCue

final class RealtimeServicePairingTests: XCTestCase {
  func testDecodesVersionedPairingPayload() throws {
    let pairing = try RealtimeServicePairing(
      payload: #"{"type":"wakeoncue.realtime-gateway","version":1,"gateway_url":"https://gateway.example.com","gateway_token":"secret-token"}"#
    )

    XCTAssertEqual(pairing.gatewayURL.absoluteString, "https://gateway.example.com")
    XCTAssertEqual(pairing.gatewayToken, "secret-token")
  }

  func testRejectsMalformedPayload() {
    XCTAssertThrowsError(try RealtimeServicePairing(payload: "not-json")) { error in
      XCTAssertEqual(error as? RealtimePairingError, .malformedPayload)
    }
  }

  func testRejectsMissingRequiredPayloadFields() {
    XCTAssertThrowsError(
      try RealtimeServicePairing(
        payload: #"{"type":"wakeoncue.realtime-gateway","version":1,"gateway_url":"https://gateway.example.com"}"#
      )
    ) { error in
      XCTAssertEqual(error as? RealtimePairingError, .malformedPayload)
    }
  }

  func testRejectsNonHTTPGatewayScheme() {
    XCTAssertThrowsError(
      try RealtimeServicePairing(
        payload: #"{"type":"wakeoncue.realtime-gateway","version":1,"gateway_url":"javascript:alert(1)","gateway_token":"secret-token"}"#
      )
    ) { error in
      XCTAssertEqual(error as? RealtimePairingError, .invalidURL)
    }
  }

  func testRejectsMissingToken() {
    XCTAssertThrowsError(
      try RealtimeServicePairing(
        payload: #"{"type":"wakeoncue.realtime-gateway","version":1,"gateway_url":"https://gateway.example.com","gateway_token":"  "}"#
      )
    ) { error in
      XCTAssertEqual(error as? RealtimePairingError, .missingToken)
    }
  }

  func testRejectsUnknownVersion() {
    XCTAssertThrowsError(
      try RealtimeServicePairing(
        payload: #"{"type":"wakeoncue.realtime-gateway","version":2,"gateway_url":"https://gateway.example.com","gateway_token":"secret-token"}"#
      )
    ) { error in
      XCTAssertEqual(error as? RealtimePairingError, .unsupportedVersion(2))
    }
  }
}
