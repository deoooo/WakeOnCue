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
  /// A phone that asked for a pairing code, while the code is on screen (and briefly after it worked).
  private(set) var pairRequest: PairRequest?
  private(set) var receivedToday = 0

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var listenerReady = false
  /// Restarts in a row that failed, e.g. while the previous listener still held the port.
  @ObservationIgnored private var listenerRetries = 0
  /// Answers `pairRequest` with its public key; nothing else is served there.
  @ObservationIgnored private var pairListener: NWListener?
  /// Takes only the key derived from the code on screen.
  @ObservationIgnored private var codeListener: NWListener?
  @ObservationIgnored private var codeExpiry: Task<Void, Never>?
  /// Phones whose request was turned down, by name, until they may ask again.
  @ObservationIgnored private var rejected: [String: Date] = [:]
  /// Shows and hides the code window.
  @ObservationIgnored var onPairRequest: ((PairRequest?) -> Void)?
  /// A phone was paired; `byCode` is false for the QR code.
  @ObservationIgnored var onPaired: ((PairedDevice, _ byCode: Bool) -> Void)?
  @ObservationIgnored private var connections: [ObjectIdentifier: (connection: NWConnection, device: String?)] = [:]
  @ObservationIgnored private let queue = DispatchQueue(label: "com.deoooo.WakeOnCue.macos.sync")
  /// Called after a segment is stored, so merging can pick it up.
  @ObservationIgnored var onSegment: ((SyncProtocol.SegmentInfo, URL) -> Void)?
  /// Called after Watch or iPhone marks are stored, with where they fall on the Mac's timeline.
  @ObservationIgnored var onMarks: (([DeviceMark]) -> Void)?
  /// Applies a delete, restore or rename made on the iPhone to one of the Mac's conversations.
  @ObservationIgnored var onLibraryEdit: ((SyncProtocol.LibraryEdit) -> Void)?

  struct PairRequest: Equatable {
    enum State: Equatable { case waiting, paired }
    var requestID: String
    var deviceName: String
    var code: String
    var expires: Date
    var failures = 0
    var state = State.waiting
  }

  static var macName: String { Host.current().localizedName ?? "Mac" }

  static var inbox: URL { Store.rootDirectory.appending(path: "Inbox", directoryHint: .isDirectory) }

  init(store: Store, preferences: Preferences) {
    self.store = store
    self.preferences = preferences
  }

  // MARK: Listening

  func start() {
    restartListener()
    updatePairListener()
  }

  func stop() {
    listener?.cancel()
    listener = nil
    pairListener?.cancel()
    pairListener = nil
    endPairRequest()
    for entry in connections.values { entry.connection.cancel() }
    connections = [:]
    connected = [:]
  }

  /// The listener carries every key it accepts, so it is rebuilt when keys change.
  private func restartListener() {
    listener?.cancel()
    listenerReady = false
    var keys = devices.map { ($0.id, $0.key) }
    if let open = PairingKeychain.invitation { keys.append((open.identity, open.key)) }
    let parameters = SyncProtocol.parameters(keys: keys)
    // The listener is rebuilt whenever keys change; the one just cancelled may still hold the port.
    parameters.allowLocalEndpointReuse = true
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
    listener.service = NWListener.Service(name: Self.macName, type: SyncProtocol.serviceType)
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, let listener, listener === self.listener else { return }
        switch state {
        case .ready:
          self.port = listener.port?.rawValue
          self.listenerReady = true
          self.listenerRetries = 0
          if let port = self.port { UserDefaults.standard.set(Int(port), forKey: "syncPort") }
          self.issue = nil
        case .failed(let error):
          Self.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
          // Try again shortly; after a few failures give up the saved port and take any free one
          // (phones find the Mac by its Bonjour name).
          guard self.listenerRetries < 6 else {
            self.issue = "本地网络监听失败：\(error.localizedDescription)"
            return
          }
          self.listenerRetries += 1
          if self.listenerRetries >= 3 { UserDefaults.standard.removeObject(forKey: "syncPort") }
          Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard listener === self.listener else { return }
            self.restartListener()
          }
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
        macID: PairingKeychain.macID, macName: Self.macName,
        service: Self.macName, host: ProcessInfo.processInfo.hostName,
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

  // MARK: Pairing with a code

  /// Advertises `pairServiceType` while 允许附近的 iPhone 请求配对码 is on. Its key is public, so
  /// it is a listener of its own: a phone connecting there can ask for a code and nothing else.
  func updatePairListener() {
    pairListener?.cancel()
    pairListener = nil
    guard preferences.allowPairRequests else {
      endPairRequest()
      return
    }
    let parameters = SyncProtocol.parameters(keys: [(SyncProtocol.pairRequestIdentity, SyncProtocol.pairRequestKey)])
    guard let listener = try? NWListener(using: parameters, on: .any) else {
      Self.logger.error("Pair listener could not start")
      return
    }
    listener.service = NWListener.Service(name: Self.macName, type: SyncProtocol.pairServiceType)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.acceptPairRequest(connection) }
    }
    pairListener = listener
    listener.start(queue: queue)
  }

  /// 拒绝 in the code window: the code stops working and that phone may not ask again for a minute.
  func rejectPairRequest() {
    if let request = pairRequest { rejected[request.deviceName] = Date().addingTimeInterval(60) }
    endPairRequest()
  }

  private func acceptPairRequest(_ connection: NWConnection) {
    connection.start(queue: queue)
    let channel = SyncChannel(connection)
    Task {
      defer { connection.cancel() }
      guard case .pairRequest(let requestID, let deviceName) = try? await channel.receive().0 else { return }
      let reply = await beginPairRequest(requestID: requestID, deviceName: deviceName)
      try? await channel.send(reply)
    }
  }

  private func beginPairRequest(requestID: String, deviceName: String) async -> SyncProtocol.Message {
    guard Self.isSafe(requestID) else {
      return .failure(segmentID: nil, reason: "配对请求无效", retry: false)
    }
    if let until = rejected[deviceName], until > .now {
      return .failure(segmentID: nil, reason: "Mac 上拒绝了这次配对", retry: false)
    }
    if let open = pairRequest, open.state == .waiting, open.expires > .now, open.deviceName != deviceName {
      return .failure(segmentID: nil, reason: "Mac 正在和另一台设备配对，请稍后再试", retry: true)
    }
    endPairRequest()
    let code = SyncProtocol.newCode()
    let key = SyncProtocol.codeKey(code: code, requestID: requestID)
    let parameters = SyncProtocol.parameters(keys: [(SyncProtocol.codeIdentity(requestID: requestID), key)])
    guard let listener = try? NWListener(using: parameters, on: .any) else {
      return .failure(segmentID: nil, reason: "Mac 无法开始配对", retry: true)
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.acceptCode(connection, requestID: requestID) }
    }
    codeListener = listener
    // The port is only usable once the listener is ready.
    let ready = await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
      let once = OnceFlag()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { continuation.resume(returning: listener.port?.rawValue) }
        case .failed, .cancelled: if once.take() { continuation.resume(returning: nil) }
        default: break
        }
      }
      listener.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 3) { if once.take() { continuation.resume(returning: nil) } }
    }
    guard listener === codeListener, let port = ready else {
      return .failure(segmentID: nil, reason: "Mac 无法开始配对", retry: true)
    }
    let expires = Date().addingTimeInterval(SyncProtocol.codeLifetime)
    setPairRequest(PairRequest(requestID: requestID, deviceName: deviceName, code: code, expires: expires))
    codeExpiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(SyncProtocol.codeLifetime))
      guard !Task.isCancelled, let self, self.pairRequest?.requestID == requestID, self.pairRequest?.state == .waiting else { return }
      self.endPairRequest()
    }
    Self.logger.notice("Showing a pairing code for \(deviceName, privacy: .public)")
    return .pairPending(macName: Self.macName, expires: expires, port: port)
  }

  /// Only a phone holding the code completes the handshake here; every failed one counts as a
  /// wrong guess.
  private func acceptCode(_ connection: NWConnection, requestID: String) {
    connection.stateUpdateHandler = { [weak self] state in
      var failed = false
      switch state {
      case .failed: failed = true
      case .waiting(let error): if case .tls = error { failed = true }
      default: break
      }
      guard failed else { return }
      Task { @MainActor in self?.wrongCode(requestID) }
      connection.cancel()
    }
    connection.start(queue: queue)
    let channel = SyncChannel(connection)
    Task {
      defer { connection.cancel() }
      guard case .pairExchange(let publicKey) = try? await channel.receive().0,
        let request = pairRequest, request.requestID == requestID, request.state == .waiting, request.expires > .now,
        let phoneKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
      else { return }
      let ours = Curve25519.KeyAgreement.PrivateKey()
      guard let secret = try? ours.sharedSecretFromKeyAgreement(with: phoneKey) else { return }
      let identity = "phone-" + UUID().uuidString.lowercased().prefix(12)
      let device = PairedDevice(
        id: String(identity), name: request.deviceName, key: SyncProtocol.pairingKey(secret, requestID: requestID),
        pairedAt: .now, lastSeen: nil)
      // A pairing from the same phone that never got as far as connecting is a leftover.
      devices.removeAll { $0.name == request.deviceName && $0.lastSeen == nil }
      devices.append(device)
      PairingKeychain.devices = devices
      codeListener?.cancel()
      codeListener = nil
      codeExpiry?.cancel()
      var paired = request
      paired.state = .paired
      setPairRequest(paired)
      // The phone connects with its new key right away: the listener must already take it.
      restartListener()
      for _ in 0..<100 where !listenerReady { try? await Task.sleep(for: .milliseconds(50)) }
      try? await channel.send(.pairAccepted(
        macID: PairingKeychain.macID, macName: Self.macName, service: Self.macName, identity: String(identity),
        publicKey: ours.publicKey.rawRepresentation, port: port ?? 0))
      Self.logger.notice("Paired \(request.deviceName, privacy: .public) with a code")
      onPaired?(device, true)
      try? await Task.sleep(for: .seconds(3))
      if pairRequest?.requestID == requestID { setPairRequest(nil) }
    }
  }

  private func wrongCode(_ requestID: String) {
    guard var request = pairRequest, request.requestID == requestID, request.state == .waiting else { return }
    request.failures += 1
    Self.logger.notice("Wrong pairing code (\(request.failures))")
    if request.failures >= SyncProtocol.codeAttempts {
      endPairRequest()
    } else {
      setPairRequest(request)
    }
  }

  private func endPairRequest() {
    codeListener?.cancel()
    codeListener = nil
    codeExpiry?.cancel()
    codeExpiry = nil
    if pairRequest != nil { setPairRequest(nil) }
  }

  private func setPairRequest(_ request: PairRequest?) {
    pairRequest = request
    onPairRequest?(request)
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
      let device = PairedDevice(id: deviceID, name: deviceName, key: open.key, pairedAt: .now, lastSeen: .now)
      devices.append(device)
      PairingKeychain.invitation = nil
      invitation = nil
      onPaired?(device, false)
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
      macName: Self.macName, accepting: preferences.autoSync, drop: drop, features: SyncProtocol.features))

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

      case .edits(let edits):
        for edit in edits where Self.isSafe(edit.id) && store.claimEdit(id: edit.id) {
          onLibraryEdit?(edit)
        }
        try await channel.send(.editsStored(ids: edits.map(\.id)))
        Self.logger.notice("Applied \(edits.count) edits from \(deviceName, privacy: .public)")

      case .libraryPull:
        let known = (try? JSONDecoder.sync.decode([String: String].self, from: body)) ?? [:]
        let library = ConversationLibrary(store: store, device: deviceID)
        let current = library.dayDigests()
        let (days, more) = library.changedDays(known: known, current: current, limit: SyncProtocol.daysPerPull)
        for key in days {
          let day = library.day(key, digest: current[key] ?? "")
          let data = try SyncProtocol.pack(day)
          try await channel.send(.libraryDay(day: key, bodyLength: data.count), body: data)
        }
        try await channel.send(.libraryEnd(more: more))
        if !days.isEmpty { Self.logger.notice("Sent \(days.count) days to \(deviceName, privacy: .public)") }

      case .audioFetch(let conversationID, let offset):
        try await sendAudio(conversationID, from: offset, device: deviceID, over: channel)

      case .bye:
        return
      default:
        try await channel.send(.failure(segmentID: nil, reason: "Mac 不处理这条消息", retry: false))
      }
    }
  }

  /// Renders the conversation's audio once per digest, then streams it from `offset`.
  private func sendAudio(_ conversationID: String, from offset: Int64, device: String, over channel: SyncChannel) async throws {
    let library = ConversationLibrary(store: store, device: device)
    guard Self.isSafe(conversationID), let conversation = library.conversation(conversationID) else {
      try await channel.send(.failure(segmentID: conversationID, reason: "Mac 上没有这段对话", retry: false))
      return
    }
    let url = ConversationAudio.cachedURL(id: conversation.id, digest: conversation.digest)
    if !FileManager.default.fileExists(atPath: url.path) {
      let range = DateInterval(start: conversation.start, end: max(conversation.end, conversation.start.addingTimeInterval(1)))
      let pieces = ConversationAudio.plan(
        range: range, segments: store.segments(overlapping: range), hidden: store.marks(overlapping: range))
      guard !pieces.isEmpty else {
        try await channel.send(.failure(segmentID: conversationID, reason: "这段对话没有音频", retry: false))
        return
      }
      let audioDirectory = store.audioDirectory
      Self.removeOldRenders(keeping: url)
      try await Task.detached(priority: .utility) {
        try ConversationAudio.render(pieces, range: range, audioDirectory: audioDirectory, to: url)
      }.value
    }
    let bytes = Self.size(of: url)
    let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: url) }.value
    try await channel.send(.audioInfo(conversationID: conversationID, digest: conversation.digest, bytes: bytes, sha256: digest, format: "m4a"))
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var position = min(max(0, offset), bytes)
    try handle.seek(toOffset: UInt64(position))
    while position < bytes {
      let data = try handle.read(upToCount: SyncProtocol.maximumChunk) ?? Data()
      guard !data.isEmpty else { break }
      try await channel.send(.audioChunk(conversationID: conversationID, offset: position, bodyLength: data.count), body: data)
      position += Int64(data.count)
    }
    try await channel.send(.audioDone(conversationID: conversationID))
  }

  /// Rendered audio is only needed while phones download it: older versions of the same
  /// conversation go at once, everything else after three days.
  private static func removeOldRenders(keeping current: URL) {
    let folder = ConversationAudio.cacheDirectory
    let cutoff = Date().addingTimeInterval(-3 * 86_400)
    let conversation = current.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
    for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let sameConversation = url.lastPathComponent.split(separator: "-").first.map(String.init) == conversation
      if modified < cutoff || sameConversation { try? FileManager.default.removeItem(at: url) }
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

/// Resumes a continuation once, whichever callback comes first.
nonisolated final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false

  func take() -> Bool {
    lock.withLock {
      defer { used = true }
      return !used
    }
  }
}
