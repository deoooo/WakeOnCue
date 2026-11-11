import CryptoKit
import Foundation
import Network
import OSLog
import Security
import WakeOnCueCore
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
    if let root = try? marksRoot() { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: Marks

  /// A mark the Mac never confirmed (an older Mac that does not take marks) is given up after this.
  static let markLifetime: TimeInterval = 60 * 86_400

  /// Marks wait in `MacOutbox/marks/<id>.json` until the Mac confirms them.
  static func marksRoot(in root: URL? = nil) throws -> URL {
    let directory = try (root ?? Self.root()).appending(path: "marks", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Queues marks for the Mac, if a Mac is paired. Queuing the same ID again replaces it, e.g.
  /// after a tag changed.
  static func enqueue(marks: [SyncProtocol.MarkInfo]) throws {
    guard MacPairing.load() != nil, !marks.isEmpty else { return }
    try enqueue(marks: marks, root: root())
  }

  static func enqueue(marks: [SyncProtocol.MarkInfo], root: URL) throws {
    let directory = try marksRoot(in: root)
    for mark in marks {
      let url = directory.appending(path: "\(fileName(mark.id)).json")
      try JSONEncoder.sync.encode(mark).write(to: url, options: .atomic)
      try? RecordingFileLayout.protect(url)
    }
  }

  /// Marks waiting for the Mac, oldest first. Ones past `markLifetime` are dropped.
  static func marks(root: URL? = nil, now: Date = .now) -> [SyncProtocol.MarkInfo] {
    guard let directory = try? marksRoot(in: root),
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".json") }.compactMap { name -> SyncProtocol.MarkInfo? in
      let url = directory.appending(path: name)
      guard let data = try? Data(contentsOf: url), let mark = try? JSONDecoder.sync.decode(SyncProtocol.MarkInfo.self, from: data)
      else { return nil }
      guard now.timeIntervalSince(mark.start) < markLifetime else {
        try? FileManager.default.removeItem(at: url)
        return nil
      }
      return mark
    }.sorted { $0.start < $1.start }
  }

  static func removeMarks(ids: [String], root: URL? = nil) {
    guard let directory = try? marksRoot(in: root) else { return }
    for id in ids { try? FileManager.default.removeItem(at: directory.appending(path: "\(fileName(id)).json")) }
  }

  /// Forgets marks in time the Mac deleted or marked private, as it does with audio.
  static func dropMarks(in drop: [SyncProtocol.Range], root: URL? = nil) {
    let dropped = marks(root: root).filter { mark in drop.contains { $0.start <= mark.start && mark.start < $0.end } }
    removeMarks(ids: dropped.map(\.id), root: root)
  }

  /// IDs are made of UUIDs and recording IDs; anything else is replaced so it stays one file name.
  private static func fileName(_ id: String) -> String {
    String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" })
  }

  /// The marks of a Watch recording: its bookmarks at their real time, under the session ID its
  /// segments carry.
  static func marks(of summary: WatchSessionSummary) -> [SyncProtocol.MarkInfo] {
    let session = summary.sessionID.uuidString.lowercased()
    return summary.bookmarks.map { bookmark in
      let start = summary.startedAt.addingTimeInterval(bookmark.position)
      return SyncProtocol.MarkInfo(
        id: "watch-\(session)-\(bookmark.id.uuidString.lowercased())", source: "watch", recordingID: session,
        start: start, end: bookmark.duration.map { start.addingTimeInterval($0) }, tag: bookmark.tag?.rawValue, title: nil)
    }
  }

  /// The bookmarks of a finished iPhone recording, which goes to the Mac as one piece starting at
  /// `startedAt`.
  static func marks(of bookmarks: [RecordingBookmark], recordingID: String, startedAt: Date) -> [SyncProtocol.MarkInfo] {
    bookmarks.map { bookmark in
      let start = startedAt.addingTimeInterval(bookmark.position)
      return SyncProtocol.MarkInfo(
        id: "iphone-\(recordingID)-\(bookmark.id.uuidString.lowercased())", source: "iphone", recordingID: recordingID,
        start: start, end: bookmark.duration.flatMap { $0 > 0 ? start.addingTimeInterval($0) : nil },
        tag: bookmark.tag?.rawValue, title: bookmark.title)
    }
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
  /// Applies the Mac's conversations to this iPhone's recordings. Unset, nothing is pulled.
  var libraryImporter: (@MainActor () -> MacLibraryImporter?)?
  /// Conversations that arrived or changed, to refresh the screens and summarize them.
  var onLibraryChanged: (@MainActor ([RecordingRecord]) async -> Void)?
  /// Audio downloads stopped because this iPhone is nearly full.
  private(set) var audioPausedForSpace = false
  /// Mac conversations whose audio is not on this iPhone yet.
  private(set) var audioWaiting = 0

  /// Connecting a Mac: the sheet, nearby Macs, the code and the QR code.
  let flow = MacPairingFlow()

  init() {
    flow.uploader = self
  }

  /// Saves `candidate` only once the Mac answered it with `welcome`, so a pairing that never
  /// reached the Mac is never kept. Waiting audio stays queued and goes to this Mac.
  func confirm(_ candidate: MacPairing) async throws {
    let channel = try await connect(candidate, timeout: 30)
    defer { channel.connection.cancel() }
    try await channel.send(.hello(deviceID: candidate.identity, deviceName: Self.deviceName, protocolVersion: SyncProtocol.version))
    let first = try await channel.receive().0
    guard case .welcome(let macName, _, _, _) = first else {
      if case .failure(_, let reason, _) = first { throw MacLinkError.refused(reason) }
      throw MacLinkError.unexpected
    }
    try? await channel.send(.bye)
    var pairing = candidate
    pairing.macName = macName
    pairing.needsRepair = false
    MacPairing.save(pairing)
    self.pairing = pairing
    status = .idle
    Self.logger.notice("Paired with \(macName, privacy: .public)")
    Task { await sync() }
  }

  func unpair() {
    MacPairing.save(nil)
    MacOutbox.removeAll()
    MacLibraryState.reset()
    pairing = nil
    pending = 0
    status = .idle
  }

  /// Sends everything in the outbox. Safe to call often; one run at a time.
  func sync() async {
    guard !running else { return }
    running = true
    // Locking the iPhone mid-download would suspend the connection; ask for time to finish.
    let backgroundTime = BackgroundTime.begin(name: "Sync with Mac")
    defer {
      running = false
      backgroundTime.end()
    }
    pending = await sendableItems().count
    guard var pairing, !pairing.needsRepair else { return }
    do {
      let channel = try await connect(pairing)
      defer { channel.connection.cancel() }
      try await channel.send(.hello(deviceID: pairing.identity, deviceName: Self.deviceName, protocolVersion: SyncProtocol.version))
      let first = try await channel.receive().0
      guard case .welcome(let macName, let accepting, let drop, let features) = first else {
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
      MacOutbox.dropMarks(in: drop)
      if accepting {
        // Checked again: a recording can be deleted while the connection was being set up.
        let items = await sendableItems()
        for (index, item) in items.enumerated() {
          // Sending can take minutes; a recording deleted meanwhile stops here.
          guard await disposition?(MacOutbox.appRecordingID(for: item.info)) ?? .send == .send else { continue }
          status = .sending(done: index, total: items.count)
          try await send(item, over: channel)
          pending = items.count - index - 1
        }
        // After the audio, so the Mac may already know the clock offset of these recordings. An
        // older Mac does not list marks and would hang up on them: they wait for an update.
        if features?.contains(SyncProtocol.Feature.marks) == true {
          try await sendMarks(over: channel)
        }
      }
      // The Mac's conversations come back whether or not it takes this iPhone's audio.
      if features?.contains(SyncProtocol.Feature.library) == true, let importer = libraryImporter?() {
        try await sendEdits(over: channel)
        try await pullLibrary(over: channel, importer: importer)
        if MacAudioPlacement.current == .both {
          try await downloadAudio(over: channel, importer: importer)
        }
      }
      try? await channel.send(.bye)
      pairing.lastSync = .now
      MacPairing.save(pairing)
      self.pairing = pairing
      status = accepting ? .idle : .failed(AppLanguage.localized("Forwarding is turned off on the Mac."))
    } catch MacLinkError.refusedKey {
      pairing.needsRepair = true
      MacPairing.save(pairing)
      self.pairing = pairing
      status = .failed(AppLanguage.localized("The Mac no longer accepts this iPhone. Scan its pairing code again."))
    } catch MacLinkError.notFound {
      status = .unreachable
    } catch SyncChannel.Failure.timedOut {
      // The next sync starts over; whatever finished is kept.
      Self.logger.error("Sync timed out")
      status = .unreachable
    } catch MacLinkError.localNetworkDenied {
      status = .failed(AppLanguage.localized("WakeOnCue needs Local Network access to reach the Mac."))
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

  private func sendMarks(over channel: SyncChannel) async throws {
    let marks = MacOutbox.marks()
    for start in stride(from: 0, to: marks.count, by: SyncProtocol.marksPerMessage) {
      let batch = Array(marks[start..<min(marks.count, start + SyncProtocol.marksPerMessage)])
      try await channel.send(.marks(batch))
      switch try await channel.receive().0 {
      case .marksStored(let ids):
        MacOutbox.removeMarks(ids: ids)
        Self.logger.notice("Stored \(ids.count) marks on the Mac")
      case .failure(_, let reason, _):
        throw MacLinkError.refused(reason)
      default:
        throw MacLinkError.unexpected
      }
    }
  }

  // MARK: The Mac's conversations

  private func sendEdits(over channel: SyncChannel) async throws {
    let edits = MacLibraryState.pendingEdits
    guard !edits.isEmpty else { return }
    try await channel.send(.edits(edits))
    switch try await channel.receive().0 {
    case .editsStored(let ids):
      MacLibraryState.removeEdits(ids: ids)
      Self.logger.notice("The Mac applied \(ids.count) edits")
    case .failure(_, let reason, _):
      throw MacLinkError.refused(reason)
    default:
      throw MacLinkError.unexpected
    }
  }

  /// Asks for changed days until the Mac has no more, applying each as it arrives.
  private func pullLibrary(over channel: SyncChannel, importer: MacLibraryImporter) async throws {
    MacLibraryState.refetchIfFormatChanged()
    var changed: [RecordingRecord] = []
    var received = 0
    var more = true
    while more {
      let known = try JSONEncoder.sync.encode(MacLibraryState.days)
      try await channel.send(.libraryPull(bodyLength: known.count), body: known)
      receiving: while true {
        let (message, body) = try await channel.receive()
        switch message {
        case .libraryDay:
          let day = try SyncProtocol.unpackDay(body)
          changed += try await importer.apply(day, language: AppLanguage.current)
          received += 1
        case .libraryEnd(let hasMore):
          more = hasMore
          break receiving
        case .failure(_, let reason, _):
          throw MacLinkError.refused(reason)
        default:
          throw MacLinkError.unexpected
        }
      }
    }
    if received > 0 {
      Self.logger.notice("Received \(received) days, \(changed.count) conversations changed")
      await onLibraryChanged?(changed)
    }
  }

  /// Newest first, while this iPhone has room. Stops, without deleting anything, when it is
  /// nearly full.
  private func downloadAudio(over channel: SyncChannel, importer: MacLibraryImporter) async throws {
    let waiting = try await importer.recordingsNeedingAudio(limit: 30)
    audioWaiting = waiting.count
    audioPausedForSpace = false
    for recording in waiting {
      guard Self.hasRoomForAudio else {
        audioPausedForSpace = true
        Self.logger.notice("Stopped downloading audio: the iPhone is nearly full")
        return
      }
      guard let conversationID = MacConversation.conversationID(of: recording) else { continue }
      let url = try RecordingFileLayout().downloadedAudioURL(recordingID: recording.id)
      _ = try await fetchAudio(conversationID, to: url, over: channel)
      audioWaiting -= 1
    }
  }

  /// Downloads one conversation's audio now, for playing it while it is not on this iPhone.
  func downloadAudioNow(for recording: RecordingRecord) async throws -> URL {
    guard let pairing, !pairing.needsRepair, let conversationID = MacConversation.conversationID(of: recording) else {
      throw MacLinkError.notFound
    }
    let url = try RecordingFileLayout().downloadedAudioURL(recordingID: recording.id)
    let channel = try await connect(pairing)
    defer { channel.connection.cancel() }
    try await channel.send(.hello(deviceID: pairing.identity, deviceName: Self.deviceName, protocolVersion: SyncProtocol.version))
    guard case .welcome(_, _, _, let features) = try await channel.receive().0,
      features?.contains(SyncProtocol.Feature.library) == true
    else { throw MacLinkError.unexpected }
    guard try await fetchAudio(conversationID, to: url, over: channel) else { throw MacLinkError.noAudio }
    try? await channel.send(.bye)
    return url
  }

  /// Resumes from what an earlier attempt left. Returns false when the Mac has no audio for it.
  private func fetchAudio(_ conversationID: String, to url: URL, over channel: SyncChannel) async throws -> Bool {
    let partial = url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".part")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let offset = Self.size(of: partial)
    try await channel.send(.audioFetch(conversationID: conversationID, offset: offset))
    let bytes: Int64
    let sha256: String
    switch try await channel.receive().0 {
    case .audioInfo(_, _, let size, let digest, _):
      bytes = size
      sha256 = digest
    case .failure(_, _, false):
      return false
    case .failure(_, let reason, true):
      throw MacLinkError.refused(reason)
    default:
      throw MacLinkError.unexpected
    }
    // The Mac's file changed since the earlier attempt: start over next time.
    if offset > bytes { try? FileManager.default.removeItem(at: partial) }
    receiving: while true {
      let (message, body) = try await channel.receive()
      switch message {
      case .audioChunk(_, let at, _):
        guard at == Self.size(of: partial) else { throw MacLinkError.unexpected }
        try Self.append(body, to: partial)
      case .audioDone:
        break receiving
      default:
        throw MacLinkError.unexpected
      }
    }
    guard Self.size(of: partial) == bytes, (try? Self.sha256(of: partial)) == sha256 else {
      try? FileManager.default.removeItem(at: partial)
      return false
    }
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: partial, to: url)
    try? RecordingFileLayout.protect(url)
    return true
  }

  /// Keeps at least 1 GB free for recording.
  private static var hasRoomForAudio: Bool {
    let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
    return free > 1 << 30
  }

  private static func size(of url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  private static func append(_ data: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  enum MacLinkError: LocalizedError {
    case notFound
    case refusedKey
    case localNetworkDenied
    case refused(String)
    case unexpected
    case noAudio

    var errorDescription: String? {
      switch self {
      case .noAudio: AppLanguage.localized("The Mac has no audio for this conversation.")
      case .notFound: AppLanguage.localized("The Mac is not on this network.")
      case .localNetworkDenied: AppLanguage.localized("WakeOnCue needs Local Network access to reach the Mac.")
      case .refusedKey: AppLanguage.localized("The Mac no longer accepts this iPhone.")
      case .refused(let reason): reason
      case .unexpected: AppLanguage.localized("The Mac sent an unexpected reply.")
      }
    }
  }

  /// Finds the Mac by its Bonjour name, falling back to the address in the code, and completes
  /// the TLS handshake with the pairing key.
  /// Long enough for the Mac to render a long conversation's audio before answering.
  static let idleTimeout: TimeInterval = 120

  private func connect(_ pairing: MacPairing, timeout: TimeInterval = 8) async throws -> SyncChannel {
    let parameters = SyncProtocol.parameters(keys: [(pairing.identity, pairing.key)])
    var endpoints: [NWEndpoint] = [.service(name: pairing.service, type: SyncProtocol.serviceType, domain: "local.", interface: nil)]
    if let port = NWEndpoint.Port(rawValue: pairing.port), pairing.port > 0, !pairing.host.isEmpty {
      endpoints.append(.hostPort(host: NWEndpoint.Host(pairing.host), port: port))
    }
    var refused = false
    var denied = false
    for endpoint in endpoints {
      let outcome = await Self.open(endpoint, using: parameters, timeout: timeout)
      Self.logger.notice("Endpoint \(String(describing: endpoint), privacy: .public) as \(pairing.identity.prefix(14), privacy: .public): \(String(describing: outcome), privacy: .public)")
      switch outcome {
      case .ready(let connection): return SyncChannel(connection, idleTimeout: Self.idleTimeout)
      case .refused: refused = true
      case .denied: denied = true
      case .unreachable: break
      }
    }
    if refused { throw MacLinkError.refusedKey }
    throw denied ? MacLinkError.localNetworkDenied : MacLinkError.notFound
  }

  enum Outcome: CustomStringConvertible {
    case ready(NWConnection)
    /// The TLS handshake failed: the Mac does not take this key.
    case refused
    /// iOS did not allow Local Network access.
    case denied
    case unreachable

    var description: String {
      switch self {
      case .ready: "ready"
      case .refused: "refused"
      case .denied: "local network denied"
      case .unreachable: "unreachable"
      }
    }
  }

  /// Opens one connection. A wrong key leaves Network in `.waiting` rather than `.failed`, so a TLS
  /// error there is a refusal. A Local Network denial also waits: the permission alert may still be
  /// on screen, so it is reported only if the connection is not ready before `timeout`.
  nonisolated static func open(_ endpoint: NWEndpoint, using parameters: NWParameters, timeout: TimeInterval) async -> Outcome {
    let connection = NWConnection(to: endpoint, using: parameters)
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
      let once = OnceFlag()
      let denied = OnceFlag()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { continuation.resume(returning: .ready(connection)) }
        case .failed: if once.take() { continuation.resume(returning: .unreachable) }
        case .waiting(let error):
          switch error {
          case .tls: if once.take() { continuation.resume(returning: .refused) }
          case .dns(let code) where code == -65570: _ = denied.take()  // kDNSServiceErr_PolicyDenied
          default: break
          }
        default: break
        }
      }
      connection.start(queue: .global(qos: .utility))
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if once.take() { continuation.resume(returning: denied.isUsed ? .denied : .unreachable) }
      }
    }
    if case .ready = outcome { return outcome }
    connection.cancel()
    return outcome
  }

  static var deviceName: String {
    #if canImport(UIKit)
      UIDevice.current.name
    #else
      Host.current().localizedName ?? "iPhone"
    #endif
  }
}

/// Resumes a continuation once, whichever callback comes first.
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false

  func take() -> Bool {
    lock.withLock {
      defer { used = true }
      return !used
    }
  }

  var isUsed: Bool { lock.withLock { used } }
}
