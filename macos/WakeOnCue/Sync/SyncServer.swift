import CryptoKit
import Foundation
import Network
import Observation
import OSLog

/// Receives Watch and iPhone audio from paired phones over the local network. Only phones that
/// scanned this Mac's pairing code have a key; everything is TLS-encrypted with it. Segments are
/// written to `Inbox/<device>/`, resumed after interruptions, checked against the phone's
/// SHA-256, and only then confirmed, so the phone never deletes audio the Mac does not have.
@Observable
final class SyncServer {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Sync")
  /// A pairing code works for this long, and only once.
  static let invitationLifetime: TimeInterval = 5 * 60

  struct Transfer: Equatable {
    var segmentID: String
    var received: Int64
    var total: Int64
  }

  private(set) var devices: [PairedDevice] = PairingKeychain.devices
  private(set) var invitation: SyncProtocol.Pairing?
  /// Phones connected now, with what they are sending.
  private(set) var connected: [String: Transfer?] = [:]
  private(set) var port: UInt16?
  private(set) var issue: String?
  private(set) var receivedToday = 0

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var connections: [ObjectIdentifier: (connection: NWConnection, device: String?)] = [:]
  @ObservationIgnored private let queue = DispatchQueue(label: "com.deoooo.WakeOnCue.macos.sync")
  /// Called after a segment is stored, so merging can pick it up.
  @ObservationIgnored var onSegment: ((SyncProtocol.SegmentInfo, URL) -> Void)?
  /// Called after Watch or iPhone marks are stored, with where they fall on the Mac's timeline.
  @ObservationIgnored var onMarks: (([DeviceMark]) -> Void)?

  static var inbox: URL { Store.rootDirectory.appending(path: "Inbox", directoryHint: .isDirectory) }

  init(store: Store, preferences: Preferences) {
    self.store = store
    self.preferences = preferences
  }

  // MARK: Listening

  func start() {
    restartListener()
  }

  func stop() {
    listener?.cancel()
    listener = nil
    for entry in connections.values { entry.connection.cancel() }
    connections = [:]
    connected = [:]
  }

  /// The listener carries every key it accepts, so it is rebuilt when keys change.
  private func restartListener() {
    listener?.cancel()
    var keys = devices.map { ($0.id, $0.key) }
    if let open = PairingKeychain.invitation { keys.append((open.identity, open.key)) }
    let parameters = SyncProtocol.parameters(keys: keys)
    let saved = UInt16(UserDefaults.standard.integer(forKey: "syncPort"))
    let listener: NWListener
    do {
      // Keep the same port across launches when possible, so a code still in a phone works.
      if saved > 0, let port = NWEndpoint.Port(rawValue: saved), let reused = try? NWListener(using: parameters, on: port) {
        listener = reused
      } else {
        listener = try NWListener(using: parameters, on: .any)
      }
    } catch {
      issue = "无法开始监听：\(error.localizedDescription)"
      return
    }
    listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: SyncProtocol.serviceType)
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, let listener, listener === self.listener else { return }
        switch state {
        case .ready:
          self.port = listener.port?.rawValue
          if let port = self.port { UserDefaults.standard.set(Int(port), forKey: "syncPort") }
          self.issue = nil
        case .failed(let error):
          self.issue = "本地网络监听失败：\(error.localizedDescription)"
          Self.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  // MARK: Pairing

  /// A new single-use code for the QR, valid for five minutes. Replaces the previous one.
  func newInvitation() {
    let identity = "phone-" + UUID().uuidString.lowercased().prefix(12)
    let key = PairingKeychain.randomKey()
    let expires = Date().addingTimeInterval(Self.invitationLifetime)
    PairingKeychain.invitation = PairingKeychain.Invitation(identity: String(identity), key: key, expires: expires)
    restartListener()
    Task {
      // Wait for the port before showing the code.
      for _ in 0..<20 where port == nil { try? await Task.sleep(for: .milliseconds(100)) }
      invitation = SyncProtocol.Pairing(
        macID: PairingKeychain.macID, macName: Host.current().localizedName ?? "Mac",
        service: Host.current().localizedName ?? "Mac", host: ProcessInfo.processInfo.hostName,
        port: port ?? 0, identity: String(identity), key: key.base64URL, expires: expires)
    }
  }

  func clearInvitation() {
    PairingKeychain.invitation = nil
    invitation = nil
    restartListener()
  }

  /// Forgets a phone: its key stops working and its connection is closed. Audio already received stays.
  func unpair(_ device: PairedDevice) {
    devices.removeAll { $0.id == device.id }
    PairingKeychain.devices = devices
    for (key, entry) in connections where entry.device == device.id {
      entry.connection.cancel()
      connections[key] = nil
    }
    connected[device.id] = nil
    restartListener()
  }

  // MARK: Connections

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connections[key] = (connection, nil)
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        Task { @MainActor in self?.closed(key) }
      default: break
      }
    }
    connection.start(queue: queue)
    let channel = SyncChannel(connection)
    Task {
      do {
        try await serve(channel, key: key)
      } catch {
        Self.logger.notice("Connection ended: \(String(describing: error), privacy: .public)")
      }
      connection.cancel()
    }
  }

  private func closed(_ key: ObjectIdentifier) {
    if let device = connections[key]?.device { connected[device] = nil }
    connections[key] = nil
  }

  private func serve(_ channel: SyncChannel, key: ObjectIdentifier) async throws {
    guard case .hello(let deviceID, let deviceName, let version) = try await channel.receive().0 else { return }
    guard version == SyncProtocol.version else {
      try await channel.send(.failure(segmentID: nil, reason: "版本不兼容，请把 iPhone 和 Mac 上的 WakeOnCue 都更新到最新", retry: false))
      return
    }
    // The TLS handshake already proved the phone holds one of the keys; the hello names which.
    if let open = PairingKeychain.invitation, open.identity == deviceID, !devices.contains(where: { $0.id == deviceID }) {
      devices.append(PairedDevice(id: deviceID, name: deviceName, key: open.key, pairedAt: .now, lastSeen: .now))
      PairingKeychain.invitation = nil
      invitation = nil
    }
    guard let index = devices.firstIndex(where: { $0.id == deviceID }) else {
      try await channel.send(.failure(segmentID: nil, reason: "这台 iPhone 还没有和这台 Mac 配对", retry: false))
      return
    }
    Self.logger.notice("Hello from \(deviceName, privacy: .public)")
    devices[index].name = deviceName
    devices[index].lastSeen = .now
    PairingKeychain.devices = devices
    connections[key]?.device = deviceID
    connected[deviceID] = .some(nil)

    let drop = store.marks(overlapping: DateInterval(start: .now.addingTimeInterval(-30 * 86_400), end: .now))
      .map { SyncProtocol.Range(kind: $0.kind.rawValue, start: $0.start, end: $0.end) }
    try await channel.send(.welcome(
      macName: Host.current().localizedName ?? "Mac", accepting: preferences.autoSync, drop: drop, features: SyncProtocol.features))

    var offered: [String: SyncProtocol.SegmentInfo] = [:]
    while true {
      let message: SyncProtocol.Message
      let body: Data
      do {
        (message, body) = try await channel.receive()
      } catch SyncChannel.Failure.unknownMessage {
        // A newer phone; tell it and keep the connection.
        try await channel.send(.failure(segmentID: nil, reason: "Mac 不认识这条消息，请把 Mac 上的 WakeOnCue 更新到最新", retry: false))
        continue
      }
      switch message {
      case .offer(let info):
        guard preferences.autoSync else {
          try await channel.send(.failure(segmentID: info.id, reason: "Mac 上关闭了自动回传", retry: true))
          continue
        }
        guard Self.isSafe(info.id), Self.isSafe(info.format), info.bytes > 0 else {
          try await channel.send(.failure(segmentID: info.id, reason: "分段信息不完整", retry: false))
          continue
        }
        if store.hasRemoteSegment(id: info.id) {
          try await channel.send(.resume(segmentID: info.id, offset: info.bytes, complete: true))
          continue
        }
        offered[info.id] = info
        let size = Self.size(of: partial(info.id, device: deviceID))
        let offset = size <= info.bytes ? size : 0
        if size > info.bytes { try? FileManager.default.removeItem(at: partial(info.id, device: deviceID)) }
        connected[deviceID] = Transfer(segmentID: info.id, received: offset, total: info.bytes)
        try await channel.send(.resume(segmentID: info.id, offset: offset, complete: false))

      case .chunk(let segmentID, let offset, _):
        guard let info = offered[segmentID] else {
          try await channel.send(.failure(segmentID: segmentID, reason: "没有先发 offer", retry: true))
          continue
        }
        let url = partial(segmentID, device: deviceID)
        let size = Self.size(of: url)
        guard offset == size, offset + Int64(body.count) <= info.bytes else {
          try await channel.send(.failure(segmentID: segmentID, reason: "偏移量对不上，请重新 offer", retry: true))
          continue
        }
        try Self.append(body, to: url)
        connected[deviceID] = Transfer(segmentID: segmentID, received: offset + Int64(body.count), total: info.bytes)

      case .commit(let segmentID):
        guard let info = offered.removeValue(forKey: segmentID) else {
          try await channel.send(.failure(segmentID: segmentID, reason: "没有先发 offer", retry: true))
          continue
        }
        let url = partial(segmentID, device: deviceID)
        let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: url) }.value
        guard Self.size(of: url) == info.bytes, digest == info.sha256.lowercased() else {
          try? FileManager.default.removeItem(at: url)
          try await channel.send(.failure(segmentID: segmentID, reason: "校验不通过，请重新发送", retry: true))
          continue
        }
        let folder = Self.inbox.appending(path: deviceID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appending(path: "\(segmentID).\(info.format)")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: url, to: final)
        store.insertRemoteSegment(info, device: deviceID, path: "\(deviceID)/\(segmentID).\(info.format)")
        receivedToday += 1
        connected[deviceID] = .some(nil)
        try await channel.send(.stored(segmentID: segmentID))
        Self.logger.notice("Stored \(segmentID, privacy: .public) from \(deviceName, privacy: .public)")
        onSegment?(info, final)

      case .marks(let marks):
        guard preferences.autoSync else {
          try await channel.send(.failure(segmentID: nil, reason: "Mac 上关闭了自动回传", retry: true))
          continue
        }
        let valid = marks.filter { Self.isSafe($0.id) }
        let saved = store.saveDeviceMarks(valid, device: deviceID, clockOffset: Merger.knownClockOffset(for: deviceID))
        // Malformed ones are confirmed too, or the phone would offer them forever.
        try await channel.send(.marksStored(ids: marks.map(\.id)))
        Self.logger.notice("Stored \(valid.count) marks from \(deviceName, privacy: .public)")
        if !saved.isEmpty { onMarks?(saved) }

      case .bye:
        return
      default:
        try await channel.send(.failure(segmentID: nil, reason: "Mac 不处理这条消息", retry: false))
      }
    }
  }

  private func partial(_ segmentID: String, device: String) -> URL {
    Self.inbox.appending(path: ".partial", directoryHint: .isDirectory).appending(path: "\(device)-\(segmentID).part")
  }

  /// IDs become file names; keep them to plain characters.
  private static func isSafe(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 120 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
      && !text.hasPrefix(".")
  }

  nonisolated static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func size(of url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  private static func append(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }
}
