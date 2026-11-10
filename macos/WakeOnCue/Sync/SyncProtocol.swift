import CryptoKit
import Foundation
import Network

/// The Mac ⇄ iPhone transfer protocol, version 1. Platform-neutral, so the iPhone side can use
/// the same file. See docs/sync-protocol.md.
///
/// Transport: TCP with TLS 1.2 PSK (TLS_PSK_WITH_AES_128_GCM_SHA256). The key and its identity
/// come from the pairing QR code, so only a paired phone can connect, and the Mac is pinned by
/// the same key. Discovery: Bonjour `_wakeoncue._tcp`, with host and port in the QR as a fallback.
///
/// Framing: every message is a 4-byte big-endian header length, the JSON header, then
/// `bodyLength` bytes of body (only `chunk` has one).
nonisolated enum SyncProtocol {
  static let version = 1
  static let serviceType = "_wakeoncue._tcp"
  /// Largest chunk body the Mac accepts.
  static let maximumChunk = 1 << 20
  /// Largest body of the other messages that carry one (a day of conversations, compressed).
  static let maximumBody = 16 << 20
  static let maximumHeader = 64 << 10
  /// Marks per `marks` message, so a header stays well under `maximumHeader`.
  static let marksPerMessage = 100

  /// What a Mac understands beyond version 1, listed in `welcome`. A phone sends a newer
  /// message only when the Mac listed it: an older Mac cannot decode it and would hang up.
  enum Feature {
    /// `marks` / `marksStored`: the Watch and iPhone "记下刚才" marks.
    static let marks = "marks"
    /// `libraryPull` … `editsStored`: the Mac's conversations, their audio and edits to them.
    static let library = "library"
  }
  /// Everything this build of the Mac understands.
  static let features = [Feature.marks, Feature.library]
  /// Days per `libraryPull` answer, so one connection never holds the Mac for long.
  static let daysPerPull = 30

  // MARK: Pairing with a code

  /// Macs that take code pairing requests advertise this next to `serviceType`, on a listener
  /// of its own: its key is public, so nothing but `pairRequest` is answered there.
  static let pairServiceType = "_wakeoncue-pair._tcp"
  static let pairRequestIdentity = "wakeoncue-pair-request"
  /// Public: it only hides the request from casual sniffing. The code is what proves the user.
  static let pairRequestKey = Data(SHA256.hash(data: Data("WakeOnCue pair request v1".utf8)))
  /// How long the code shown on the Mac works, and how many wrong tries it survives.
  static let codeLifetime: TimeInterval = 120
  static let codeAttempts = 5

  /// A six-digit code, uniformly random.
  static func newCode() -> String {
    String(format: "%06d", Int.random(in: 0..<1_000_000))
  }

  static func codeIdentity(requestID: String) -> String { "pair-" + requestID }

  /// The PSK both sides derive from the code. A wrong code fails the TLS handshake, so guessing
  /// takes one live connection per try; the Mac drops the code after `codeAttempts` failures.
  static func codeKey(code: String, requestID: String) -> Data {
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data(requestID.utf8),
      info: Data("WakeOnCue pairing code".utf8), outputByteCount: 32)
    return key.withUnsafeBytes { Data($0) }
  }

  /// The long-term key, from an X25519 exchange inside the code-authenticated channel: someone
  /// who records the exchange and later brute-forces the code still cannot compute it.
  static func pairingKey(_ secret: SharedSecret, requestID: String) -> Data {
    let key = secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(requestID.utf8), sharedInfo: Data("WakeOnCue pairing key".utf8), outputByteCount: 32)
    return key.withUnsafeBytes { Data($0) }
  }

  /// TLS 1.2 with a pre-shared key; both sides use the same options.
  static func tlsOptions(keys: [(identity: String, key: Data)]) -> NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    // TLS_PSK_WITH_AES_128_GCM_SHA256
    sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: 0x00A8)!)
    for (identity, key) in keys {
      let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
      let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
      sec_protocol_options_add_pre_shared_key(security, keyData as __DispatchData, identityData as __DispatchData)
    }
    return tls
  }

  static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    let parameters = NWParameters(tls: tlsOptions(keys: keys), tcp: tcp)
    parameters.includePeerToPeer = false
    return parameters
  }

  /// What the pairing QR code carries.
  struct Pairing: Codable, Equatable {
    var version = SyncProtocol.version
    /// This Mac, stable across pairings.
    var macID: String
    var macName: String
    var service: String
    var host: String
    var port: UInt16
    /// The PSK identity, unique per paired phone.
    var identity: String
    /// The 32-byte key, base64url.
    var key: String
    var expires: Date

    var url: URL {
      var components = URLComponents()
      components.scheme = "wakeoncue"
      components.host = "pair"
      let data = (try? JSONEncoder.sync.encode(self)) ?? Data()
      components.queryItems = [URLQueryItem(name: "p", value: data.base64URL)]
      return components.url!
    }

    init(macID: String, macName: String, service: String, host: String, port: UInt16, identity: String, key: String, expires: Date) {
      self.macID = macID
      self.macName = macName
      self.service = service
      self.host = host
      self.port = port
      self.identity = identity
      self.key = key
      self.expires = expires
    }

    init?(url: URL) {
      guard url.scheme == "wakeoncue", url.host() == "pair",
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value,
        let data = Data(base64URL: value), let pairing = try? JSONDecoder.sync.decode(Pairing.self, from: data)
      else { return nil }
      self = pairing
    }
  }

  /// A time range the phone must drop audio for: paused, private or deleted on the Mac.
  struct Range: Codable, Equatable {
    var kind: String
    var start: Date
    var end: Date
  }

  /// One piece of audio to hand over: a Watch segment or an iPhone recording piece.
  struct SegmentInfo: Codable, Equatable {
    /// Unique and stable across retries, e.g. "watch-<session>-0003".
    var id: String
    /// "watch" or "iphone".
    var source: String
    var recordingID: String
    var index: Int
    var startedAt: Date
    var duration: TimeInterval
    var bytes: Int64
    /// Lowercase hex SHA-256 of the whole file.
    var sha256: String
    /// File extension, e.g. "m4a".
    var format: String
  }

  /// A moment the user marked on the Watch or the iPhone ("记下刚才" or a bookmark), in the
  /// device's own clock. The Mac shifts it by the clock offset it learned for that recording.
  struct MarkInfo: Codable, Equatable {
    /// Unique and stable across retries, e.g. "watch-<session>-<bookmark>".
    var id: String
    /// "watch" or "iphone".
    var source: String
    /// The `recordingID` of the segments this mark belongs to.
    var recordingID: String
    var start: Date
    /// Nil for a point mark.
    var end: Date?
    /// "todo", "important" or "idea"; nil when not tagged.
    var tag: String?
    var title: String?
  }

  // MARK: The Mac's conversations

  /// One transcribed sentence. `speaker` is "me" or "other"; `name` a person's name when known.
  struct LibrarySentence: Codable, Equatable {
    var id: Int64
    var start: Date
    var end: Date
    var speaker: String
    var name: String?
    var text: String
  }

  /// A recording from the phone asking, whose audio is part of a conversation.
  struct DeviceRecording: Codable, Equatable, Hashable {
    /// "watch" or "iphone".
    var source: String
    /// The `SegmentInfo.recordingID` the phone sent it under.
    var recordingID: String
  }

  /// A stretch of talk on the Mac's timeline: sentences with no silence longer than
  /// `ConversationRules.gap` between them, never across midnight. Private and deleted time is
  /// already left out.
  struct LibraryConversation: Codable, Equatable {
    /// Stable while the conversation keeps its first sentence.
    var id: String
    var start: Date
    var end: Date
    /// Where the audio came from, e.g. ["Mac", "Apple Watch"].
    var sources: [String]
    /// The user's own title for it, if they gave one.
    var title: String?
    var overview: String?
    var keyPoints: [String]
    var todos: [String]
    var sentences: [LibrarySentence]
    /// This phone's recordings that the conversation includes, so the phone can stop showing them
    /// on their own.
    var deviceRecordings: [DeviceRecording]
    /// Changes whenever anything above does.
    var digest: String
  }

  /// Everything one day holds. A conversation the phone has for this day but that is not listed
  /// here was deleted, marked private or merged into another.
  struct LibraryDay: Codable, Equatable {
    /// "yyyy-MM-dd" in the Mac's time zone.
    var day: String
    var digest: String
    var conversations: [LibraryConversation]
  }

  /// A change made on the phone to one of the Mac's conversations.
  struct LibraryEdit: Codable, Equatable {
    enum Kind: String, Codable {
      /// Deletes the conversation's time on the Mac (restorable there for 30 days).
      case delete
      /// Undoes `delete`.
      case restore
      /// Sets the title; an empty `value` clears it.
      case rename
    }

    /// Unique per edit, so a resent one is applied once.
    var id: String
    var conversationID: String
    var start: Date
    var end: Date
    var kind: Kind
    var value: String?
    var madeAt: Date
  }

  enum Message: Codable, Equatable {
    /// Phone → Mac, first message.
    case hello(deviceID: String, deviceName: String, protocolVersion: Int)
    /// Mac → phone. `accepting` is the user's 自动回传 switch; `drop` lists ranges whose audio
    /// the phone deletes without sending. `features` is missing from older Macs.
    case welcome(macName: String, accepting: Bool, drop: [Range], features: [String]?)
    /// Phone → Mac: wants to send this segment.
    case offer(SegmentInfo)
    /// Mac → phone: send from `offset`; `complete` means it is already stored and can be deleted.
    case resume(segmentID: String, offset: Int64, complete: Bool)
    /// Phone → Mac: `bodyLength` bytes at `offset`, in the frame body.
    case chunk(segmentID: String, offset: Int64, bodyLength: Int)
    /// Phone → Mac: all bytes sent.
    case commit(segmentID: String)
    /// Mac → phone: verified and stored; the phone may delete its copy now.
    case stored(segmentID: String)
    /// Phone → Mac, only when `welcome` listed `Feature.marks`: marks to store or update.
    case marks([MarkInfo])
    /// Mac → phone: these marks are stored; the phone may forget them.
    case marksStored(ids: [String])
    /// Phone → Mac, on the pair listener: please show a code. `requestID` is fresh per request.
    /// Phone → Mac, only when `welcome` listed `Feature.library`. Body: JSON `[day: digest]` of
    /// the days the phone already has. The Mac answers with up to `daysPerPull` `libraryDay`s,
    /// newest first, for days whose digest differs, then `libraryEnd`.
    case libraryPull(bodyLength: Int)
    /// Mac → phone. Body: zlib-compressed JSON `LibraryDay`.
    case libraryDay(day: String, bodyLength: Int)
    /// Mac → phone: `more` means another `libraryPull` will bring older days.
    case libraryEnd(more: Bool)
    /// Phone → Mac: wants a conversation's audio from `offset`. The Mac answers `audioInfo`, then
    /// `audioChunk`s, then `audioDone`; or `failure` when there is no audio.
    case audioFetch(conversationID: String, offset: Int64)
    /// Mac → phone: the whole file's size and SHA-256. The same conversation with the same digest
    /// always gives the same file, so an interrupted download resumes.
    case audioInfo(conversationID: String, digest: String, bytes: Int64, sha256: String, format: String)
    /// Mac → phone: `bodyLength` bytes at `offset`, in the frame body.
    case audioChunk(conversationID: String, offset: Int64, bodyLength: Int)
    case audioDone(conversationID: String)
    /// Phone → Mac, only with `Feature.library`: edits made on the phone.
    case edits([LibraryEdit])
    /// Mac → phone: applied; the phone forgets them.
    case editsStored(ids: [String])
    case pairRequest(requestID: String, deviceName: String)
    /// Mac → phone: a code is on screen until `expires`; connect to `port` on this host with
    /// `codeKey(code, requestID)` under `codeIdentity(requestID)`.
    case pairPending(macName: String, expires: Date, port: UInt16)
    /// Phone → Mac, on the code listener: the phone's X25519 public key.
    case pairExchange(publicKey: Data)
    /// Mac → phone: paired. The phone's PSK is `pairingKey` under `identity`; `service` is the
    /// Bonjour name of the Mac's main listener and `port` its port.
    case pairAccepted(macID: String, macName: String, service: String, identity: String, publicKey: Data, port: UInt16)
    /// Either way: something is wrong; `retry` says whether trying again later can help.
    case failure(segmentID: String?, reason: String, retry: Bool)
    case bye

    var bodyLength: Int {
      switch self {
      case .chunk(_, _, let length), .audioChunk(_, _, let length), .libraryPull(let length),
        .libraryDay(_, let length):
        return length
      default:
        return 0
      }
    }

    /// Audio travels in chunks of at most `maximumChunk`; a day of text may be larger.
    var maximumBody: Int {
      switch self {
      case .chunk, .audioChunk: SyncProtocol.maximumChunk
      default: SyncProtocol.maximumBody
      }
    }
  }

  static func frame(_ message: Message, body: Data = Data()) throws -> Data {
    let header = try JSONEncoder.sync.encode(message)
    var data = Data()
    var length = UInt32(header.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(header)
    data.append(body)
    return data
  }

  /// A JSON header this build does not know throws `SyncChannel.Failure.unknownMessage`, which
  /// leaves the connection usable (only `chunk` has a body, and every build knows `chunk`);
  /// anything that is not JSON throws `badFrame`.
  static func decodeHeader(_ header: Data) throws -> Message {
    if let message = try? JSONDecoder.sync.decode(Message.self, from: header) { return message }
    guard (try? JSONSerialization.jsonObject(with: header)) is [String: Any] else { throw SyncChannel.Failure.badFrame }
    throw SyncChannel.Failure.unknownMessage
  }
}

/// Reads and writes framed messages on a connection.
nonisolated final class SyncChannel: @unchecked Sendable {
  enum Failure: Error {
    case closed
    case badFrame
    /// A well-formed frame with a message this build does not know, e.g. from a newer phone.
    /// The connection is still usable.
    case unknownMessage
  }

  let connection: NWConnection

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func send(_ message: SyncProtocol.Message, body: Data = Data()) async throws {
    let data = try SyncProtocol.frame(message, body: body)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  func receive() async throws -> (SyncProtocol.Message, Data) {
    let lengthBytes = try await read(4)
    let length = lengthBytes.reduce(0) { $0 << 8 | Int($1) }
    guard length > 0, length <= SyncProtocol.maximumHeader else { throw Failure.badFrame }
    let message = try SyncProtocol.decodeHeader(try await read(length))
    let bodyLength = message.bodyLength
    guard bodyLength >= 0, bodyLength <= message.maximumBody else { throw Failure.badFrame }
    return (message, bodyLength > 0 ? try await read(bodyLength) : Data())
  }

  private func read(_ count: Int) async throws -> Data {
    var data = Data()
    while data.count < count {
      let part: Data = try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { content, _, isComplete, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let content, !content.isEmpty {
            continuation.resume(returning: content)
          } else if isComplete {
            continuation.resume(throwing: Failure.closed)
          } else {
            continuation.resume(returning: Data())
          }
        }
      }
      data.append(part)
    }
    return data
  }
}

nonisolated extension SyncProtocol {
  /// A `LibraryDay` as the `libraryDay` body.
  static func pack(_ day: LibraryDay) throws -> Data {
    try (JSONEncoder.sync.encode(day) as NSData).compressed(using: .zlib) as Data
  }

  static func unpackDay(_ body: Data) throws -> LibraryDay {
    try JSONDecoder.sync.decode(LibraryDay.self, from: (body as NSData).decompressed(using: .zlib) as Data)
  }

  /// Lowercase hex SHA-256 of text, for digests.
  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

nonisolated extension JSONEncoder {
  static var sync: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

nonisolated extension JSONDecoder {
  static var sync: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

nonisolated extension Data {
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL: String) {
    var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    self.init(base64Encoded: text)
  }
}
