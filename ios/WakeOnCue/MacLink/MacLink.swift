import CryptoKit
import Foundation
import Network
import OSLog
import Security
#if canImport(UIKit)
  import UIKit
#endif

/// The Mac this iPhone forwards Watch and iPhone audio to, from the pairing QR code. The key
/// lives in the keychain, never in settings or backups.
struct MacPairing: Codable, Equatable, Sendable {
  var macID: String
  var macName: String
  var service: String
  var host: String
  var port: UInt16
  var identity: String
  var key: Data
  var pairedAt: Date
  var lastSync: Date?
  /// Set when the Mac refused this key, e.g. after it was unpaired there.
  var needsRepair = false

  private static let service = "com.deoooo.WakeOnCue.mac-pairing"

  static func load() -> MacPairing? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "mac", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder.sync.decode(MacPairing.self, from: data)
  }

  static func save(_ pairing: MacPairing?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mac",
    ]
    SecItemDelete(query as CFDictionary)
    guard let pairing, let data = try? JSONEncoder.sync.encode(pairing) else { return }
    var attributes = query
    attributes[kSecValueData as String] = data
    // Available in the background after the first unlock, when Watch segments arrive.
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(attributes as CFDictionary, nil)
  }
}

/// Audio waiting for the Mac: a hard link (or copy) of each Watch segment and finished iPhone
/// recording, with its description. An item is removed only after the Mac confirmed it.
enum MacOutbox {
  struct Item: Sendable {
    let info: SyncProtocol.SegmentInfo
    let file: URL
    let descriptor: URL
  }

  /// What happens to an item, given the state of its recording on this iPhone.
  enum Disposition: Sendable {
    case send
    /// In Recently Deleted: kept in case it is recovered, but not sent.
    case hold
    /// Permanently deleted: removed without being sent.
    case discard
  }

  static func root(override: URL? = nil) throws -> URL {
    let directory = try override ?? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "MacOutbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Queues a file for the Mac, if a Mac is paired. The file is linked, not moved, so the rest
  /// of the app can keep using and deleting its own copy.
  static func enqueue(
    file: URL, id: String, source: String, recordingID: String, index: Int, startedAt: Date, duration: TimeInterval
  ) throws {
    guard MacPairing.load() != nil else { return }
    try add(
      file: file, id: id, source: source, recordingID: recordingID, index: index, startedAt: startedAt,
      duration: duration)
  }

  static func add(
    file: URL, id: String, source: String, recordingID: String, index: Int, startedAt: Date, duration: TimeInterval,
    root override: URL? = nil
  ) throws {
    let root = try root(override: override)
    let format = file.pathExtension.isEmpty ? "m4a" : file.pathExtension
    let destination = root.appending(path: "\(id).\(format)")
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.linkItem(at: file, to: destination)
    } catch {
      try FileManager.default.copyItem(at: file, to: destination)
    }
    try? RecordingFileLayout.protect(destination)
    let data = try Data(contentsOf: destination, options: .mappedIfSafe)
    let info = SyncProtocol.SegmentInfo(
      id: id, source: source, recordingID: recordingID, index: index, startedAt: startedAt, duration: duration,
      bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), format: format)
    try JSONEncoder.sync.encode(info).write(to: root.appending(path: "\(id).json"), options: .atomic)
  }

  /// The recording on this iPhone that an item belongs to. A Watch segment names its Watch
  /// session, which becomes a recording only once imported.
  static func appRecordingID(for info: SyncProtocol.SegmentInfo) -> String {
    guard info.source == "watch", let sessionID = UUID(uuidString: info.recordingID) else {
      return info.recordingID
    }
    return WatchSessionSummary.recordingID(for: sessionID)
  }

  static func items(root override: URL? = nil) -> [Item] {
    guard let root = try? root(override: override),
      let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".json") }.compactMap { name in
      let descriptor = root.appending(path: name)
      guard let data = try? Data(contentsOf: descriptor), let info = try? JSONDecoder.sync.decode(SyncProtocol.SegmentInfo.self, from: data)
      else { return nil }
      let file = root.appending(path: "\(info.id).\(info.format)")
      guard FileManager.default.fileExists(atPath: file.path) else {
        try? FileManager.default.removeItem(at: descriptor)
        return nil
      }
      return Item(info: info, file: file, descriptor: descriptor)
    }.sorted { $0.info.startedAt < $1.info.startedAt }
  }

  /// Items to send now. Removes those of permanently deleted recordings and leaves those in
  /// Recently Deleted waiting.
  static func sendableItems(
    root override: URL? = nil, disposition: @Sendable (String) async -> Disposition
  ) async -> [Item] {
    var sendable: [Item] = []
    for item in items(root: override) {
      switch await disposition(appRecordingID(for: item.info)) {
      case .send: sendable.append(item)
      case .hold: continue
      case .discard: remove(item)
      }
    }
    return sendable
  }

  static func remove(_ item: Item) {
    try? FileManager.default.removeItem(at: item.file)
    try? FileManager.default.removeItem(at: item.descriptor)
  }

  /// Removes everything queued for a recording on this iPhone, e.g. when it is permanently deleted.
  static func remove(appRecordingID: String, root override: URL? = nil) {
    for item in items(root: override) where Self.appRecordingID(for: item.info) == appRecordingID {
      remove(item)
    }
  }

  static func removeAll() {
    for item in items() { remove(item) }
  }
}

/// Sends the outbox to the paired Mac over the local network (protocol in docs/sync-protocol.md).
/// Runs when the app opens, when a Watch segment arrives, and on background refresh.
@MainActor
@Observable
final class MacUploader {
  enum Status: Equatable {
    case idle
    case sending(done: Int, total: Int)
    case unreachable
    case failed(String)
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue", category: "MacLink")

  private(set) var pairing: MacPairing? = MacPairing.load()
  private(set) var status: Status = .idle
  private(set) var pending = MacOutbox.items().count
  private var running = false
  /// Decides, per recording on this iPhone, whether its audio may go to the Mac. Unset, all goes.
  var disposition: (@MainActor @Sendable (String) async -> MacOutbox.Disposition)?

  /// Handles `wakeoncue://pair?…` from the Mac's QR code.
  func pair(with url: URL) -> Bool {
    guard let code = SyncProtocol.Pairing(url: url), let key = Data(base64URL: code.key) else { return false }
    Self.logger.notice("Pairing with \(code.macName, privacy: .public) at \(code.host, privacy: .public):\(code.port)")
    guard code.expires > .now else {
      status = .failed(AppLanguage.localized("This pairing code has expired. Refresh it on the Mac."))
      return true
    }
    let pairing = MacPairing(
      macID: code.macID, macName: code.macName, service: code.service, host: code.host, port: code.port,
      identity: code.identity, key: key, pairedAt: .now)
    MacPairing.save(pairing)
    self.pairing = pairing
    status = .idle
    Task { await sync() }
    return true
  }

  func unpair() {
    MacPairing.save(nil)
    MacOutbox.removeAll()
    pairing = nil
    pending = 0
    status = .idle
  }

  /// Sends everything in the outbox. Safe to call often; one run at a time.
  func sync() async {
    guard !running else { return }
    running = true
    defer { running = false }
    pending = await sendableItems().count
    guard var pairing, !pairing.needsRepair else { return }
    do {
      let channel = try await connect(pairing)
      defer { channel.connection.cancel() }
      try await channel.send(.hello(deviceID: pairing.identity, deviceName: Self.deviceName, protocolVersion: SyncProtocol.version))
      let first = try await channel.receive().0
      guard case .welcome(let macName, let accepting, let drop) = first else {
        if case .failure(_, let reason, _) = first { throw MacLinkError.refused(reason) }
        Self.logger.error("Unexpected first reply: \(String(describing: first), privacy: .public)")
        throw MacLinkError.unexpected
      }
      Self.logger.notice("Connected to \(macName, privacy: .public), accepting \(accepting), \(self.pending) waiting")
      pairing.macName = macName
      // The Mac deleted or marked these times private: their audio never leaves this iPhone.
      for item in MacOutbox.items() where drop.contains(where: { $0.start <= item.info.startedAt && item.info.startedAt < $0.end }) {
        MacOutbox.remove(item)
      }
      guard accepting else {
        status = .failed(AppLanguage.localized("Forwarding is turned off on the Mac."))
        return
      }
      // Checked again: a recording can be deleted while the connection was being set up.
      let items = await sendableItems()
      for (index, item) in items.enumerated() {
        // Sending can take minutes; a recording deleted meanwhile stops here.
        guard await disposition?(MacOutbox.appRecordingID(for: item.info)) ?? .send == .send else { continue }
        status = .sending(done: index, total: items.count)
        try await send(item, over: channel)
        pending = items.count - index - 1
      }
      try? await channel.send(.bye)
      pairing.lastSync = .now
      MacPairing.save(pairing)
      self.pairing = pairing
      status = .idle
    } catch MacLinkError.refusedKey {
      pairing.needsRepair = true
      MacPairing.save(pairing)
      self.pairing = pairing
      status = .failed(AppLanguage.localized("The Mac no longer accepts this iPhone. Scan its pairing code again."))
    } catch MacLinkError.notFound {
      status = .unreachable
    } catch {
      Self.logger.error("Sync failed: \(String(describing: error), privacy: .public)")
      status = .failed(error.localizedDescription)
    }
    pending = await sendableItems().count
  }

  private func sendableItems() async -> [MacOutbox.Item] {
    guard let disposition else { return MacOutbox.items() }
    return await MacOutbox.sendableItems(disposition: disposition)
  }

  private func send(_ item: MacOutbox.Item, over channel: SyncChannel) async throws {
    try await channel.send(.offer(item.info))
    switch try await channel.receive().0 {
    case .resume(_, _, true):
      MacOutbox.remove(item)
      return
    case .resume(_, let offset, false):
      let handle = try FileHandle(forReadingFrom: item.file)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      var position = offset
      while position < item.info.bytes {
        let data = try handle.read(upToCount: SyncProtocol.maximumChunk) ?? Data()
        guard !data.isEmpty else { throw MacLinkError.unexpected }
        try await channel.send(.chunk(segmentID: item.info.id, offset: position, bodyLength: data.count), body: data)
        position += Int64(data.count)
      }
      try await channel.send(.commit(segmentID: item.info.id))
      guard case .stored = try await channel.receive().0 else { throw MacLinkError.unexpected }
      Self.logger.notice("Stored \(item.info.id, privacy: .public) on the Mac (resumed at \(offset))")
      MacOutbox.remove(item)
    case .failure(_, let reason, _):
      throw MacLinkError.refused(reason)
    default:
      throw MacLinkError.unexpected
    }
  }

  private enum MacLinkError: LocalizedError {
    case notFound
    case refusedKey
    case refused(String)
    case unexpected

    var errorDescription: String? {
      switch self {
      case .notFound: AppLanguage.localized("The Mac is not on this network.")
      case .refusedKey: AppLanguage.localized("The Mac no longer accepts this iPhone.")
      case .refused(let reason): reason
      case .unexpected: AppLanguage.localized("The Mac sent an unexpected reply.")
      }
    }
  }

  /// Finds the Mac by its Bonjour name, falling back to the address in the code, and completes
  /// the TLS handshake with the pairing key. A wrong key leaves Network in `.waiting` rather than
  /// `.failed`, so a TLS error there is treated as a refusal.
  private func connect(_ pairing: MacPairing) async throws -> SyncChannel {
    let parameters = SyncProtocol.parameters(keys: [(pairing.identity, pairing.key)])
    var endpoints: [NWEndpoint] = [.service(name: pairing.service, type: SyncProtocol.serviceType, domain: "local.", interface: nil)]
    if let port = NWEndpoint.Port(rawValue: pairing.port), pairing.port > 0 {
      endpoints.append(.hostPort(host: NWEndpoint.Host(pairing.host), port: port))
    }
    var refused = false
    for endpoint in endpoints {
      let connection = NWConnection(to: endpoint, using: parameters)
      let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
        let once = OnceFlag()
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: if once.take() { continuation.resume(returning: true) }
          case .failed: if once.take() { continuation.resume(returning: false) }
          case .waiting(let error):
            if case .tls = error {
              if once.take() { continuation.resume(returning: nil) }
            } else if once.take() {
              continuation.resume(returning: false)
            }
          default: break
          }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if once.take() { continuation.resume(returning: false) } }
      }
      Self.logger.notice("Endpoint \(String(describing: endpoint), privacy: .public) as \(pairing.identity.prefix(14), privacy: .public): \(outcome.map { $0 ? "ready" : "failed" } ?? "refused", privacy: .public)")
      switch outcome {
      case true: return SyncChannel(connection)
      case nil:
        refused = true
        connection.cancel()
      default:
        connection.cancel()
      }
    }
    throw refused ? MacLinkError.refusedKey : MacLinkError.notFound
  }

  private static var deviceName: String {
    #if canImport(UIKit)
      UIDevice.current.name
    #else
      Host.current().localizedName ?? "iPhone"
    #endif
  }
}

/// Resumes a continuation once, whichever callback comes first.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false

  func take() -> Bool {
    lock.withLock {
      defer { used = true }
      return !used
    }
  }
}
