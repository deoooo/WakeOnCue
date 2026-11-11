import Foundation
import Network
import XCTest

/// Watch and iPhone marks: the protocol messages, storing them, and placing them on the Mac's
/// timeline with the clock offset learned from the same recording's audio.
nonisolated final class DeviceMarkTests: XCTestCase {
  private var directory: URL!
  private var store: Store!
  /// 10:00 on a fixed day, local time.
  private var ten: Date!

  override func setUpWithError() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "DeviceMarkTests-\(UUID().uuidString)")
    self.directory = directory
    // XCTest calls setUp on the main thread.
    store = try MainActor.assumeIsolated { try Store(directory: directory) }
    let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    ten = day.addingTimeInterval(10 * 3_600)
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func mark(_ id: String, recording: String = "session-1", at start: Date, length: TimeInterval? = 120, tag: String? = "important") -> SyncProtocol.MarkInfo {
    SyncProtocol.MarkInfo(
      id: id, source: "watch", recordingID: recording, start: start, end: length.map { start.addingTimeInterval($0) },
      tag: tag, title: nil)
  }

  // MARK: Protocol

  @MainActor func testMarksMessagesRoundTrip() throws {
    let messages: [SyncProtocol.Message] = [
      .welcome(macName: "Mac", accepting: true, drop: [], features: SyncProtocol.features),
      .marks([mark("watch-1", at: ten), mark("watch-2", at: ten, length: nil, tag: nil)]),
      .marksStored(ids: ["watch-1", "watch-2"]),
    ]
    for message in messages {
      let frame = try SyncProtocol.frame(message)
      let length = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
      XCTAssertEqual(frame.count, 4 + length)
      XCTAssertEqual(try SyncProtocol.decodeHeader(frame.dropFirst(4)), message)
    }
  }

  @MainActor func testWelcomeFromAnOlderMacHasNoFeatures() throws {
    let message = try SyncProtocol.decodeHeader(Data(#"{"welcome":{"macName":"Mac","accepting":true,"drop":[]}}"#.utf8))
    XCTAssertEqual(message, .welcome(macName: "Mac", accepting: true, drop: [], features: nil))
  }

  @MainActor func testOlderPhonesIgnoreTheNewWelcomeField() throws {
    // An older phone decodes `welcome` with three fields; the extra one must not break that.
    struct OldWelcome: Decodable {
      struct Body: Decodable {
        var macName: String
        var accepting: Bool
        var drop: [SyncProtocol.Range]
      }
      var welcome: Body
    }
    let header = try JSONEncoder.sync.encode(
      SyncProtocol.Message.welcome(macName: "Mac", accepting: false, drop: [], features: SyncProtocol.features))
    XCTAssertEqual(try JSONDecoder.sync.decode(OldWelcome.self, from: header).welcome.macName, "Mac")
  }

  @MainActor func testUnknownMessagesKeepTheConnection() {
    XCTAssertThrowsError(try SyncProtocol.decodeHeader(Data(#"{"somethingNew":{"x":1}}"#.utf8))) { error in
      guard case SyncChannel.Failure.unknownMessage = error else { return XCTFail("\(error)") }
    }
    XCTAssertThrowsError(try SyncProtocol.decodeHeader(Data("not json".utf8))) { error in
      guard case SyncChannel.Failure.badFrame = error else { return XCTFail("\(error)") }
    }
  }

  @MainActor func testMacListsMarks() {
    XCTAssertTrue(SyncProtocol.features.contains(SyncProtocol.Feature.marks))
  }

  // MARK: Storing and aligning

  @MainActor func testMarksTakeTheDeviceOffsetUntilTheirAudioIsMerged() {
    let saved = store.saveDeviceMarks([mark("watch-1", at: ten)], device: "phone-a", clockOffset: 2)

    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved[0].start, ten.addingTimeInterval(2))
    XCTAssertEqual(saved[0].end, ten.addingTimeInterval(122))
    XCTAssertEqual(saved[0].tag, .important)
    XCTAssertEqual(saved[0].sourceLabel, "Apple Watch")

    // The recording's audio is merged and turns out to be 1.5 s off: the mark follows it.
    store.insertRemoteSegment(segment("seg-1", recording: "session-1"), device: "phone-a", path: "phone-a/seg-1.m4a")
    store.finishRemoteSegment(id: "seg-1", outcome: "filled", clockOffset: -1.5)
    XCTAssertEqual(store.deviceMarks(ids: ["watch-1"]).first?.start, ten.addingTimeInterval(-1.5))
  }

  @MainActor func testMarksArrivingAfterTheirAudioUseItsOffset() {
    store.insertRemoteSegment(segment("seg-1", recording: "session-1"), device: "phone-a", path: "phone-a/seg-1.m4a")
    store.finishRemoteSegment(id: "seg-1", outcome: "duplicate", clockOffset: 0.8)

    let saved = store.saveDeviceMarks(
      [mark("watch-1", at: ten), mark("watch-2", recording: "session-2", at: ten)], device: "phone-a", clockOffset: 3)

    XCTAssertEqual(saved.first { $0.id == "watch-1" }?.start, ten.addingTimeInterval(0.8))
    XCTAssertEqual(saved.first { $0.id == "watch-2" }?.start, ten.addingTimeInterval(3), "no audio of that recording yet")
  }

  @MainActor func testOtherDevicesDoNotMoveMarks() {
    store.saveDeviceMarks([mark("watch-1", at: ten)], device: "phone-a", clockOffset: 0)
    store.insertRemoteSegment(segment("seg-1", recording: "session-1"), device: "phone-b", path: "phone-b/seg-1.m4a")
    store.finishRemoteSegment(id: "seg-1", outcome: "kept", clockOffset: 5)
    XCTAssertEqual(store.deviceMarks(ids: ["watch-1"]).first?.start, ten)
  }

  @MainActor func testSendingAgainUpdatesTheMark() {
    store.saveDeviceMarks([mark("watch-1", at: ten, tag: nil)], device: "phone-a", clockOffset: 0)
    store.saveDeviceMarks([mark("watch-1", at: ten, tag: "todo")], device: "phone-a", clockOffset: 0)
    let marks = store.deviceMarks(overlapping: DateInterval(start: ten, duration: 3_600))
    XCTAssertEqual(marks.map(\.id), ["watch-1"])
    XCTAssertEqual(marks.first?.tag, .todo)
  }

  @MainActor func testPointMarksAndOverlap() {
    store.saveDeviceMarks(
      [mark("point", at: ten, length: nil, tag: nil), mark("span", at: ten.addingTimeInterval(-60), length: 120)],
      device: "phone-a", clockOffset: 0)
    XCTAssertEqual(store.deviceMarks(overlapping: DateInterval(start: ten, duration: 60)).map(\.id), ["span", "point"])
    XCTAssertEqual(store.deviceMarks(ids: ["point"]).first?.end, nil)
    XCTAssertEqual(store.deviceMarks(ids: ["point"]).first?.label, "标记")
    XCTAssertTrue(store.deviceMarks(overlapping: DateInterval(start: ten.addingTimeInterval(61), duration: 60)).isEmpty)
  }

  @MainActor func testDeletingARangeDeletesItsMarks() {
    store.saveDeviceMarks([mark("watch-1", at: ten), mark("watch-2", at: ten.addingTimeInterval(7_200))], device: "phone-a", clockOffset: 0)
    store.purge(DateInterval(start: ten, duration: 3_600))
    XCTAssertEqual(store.deviceMarks(overlapping: DateInterval(start: ten, duration: 86_400)).map(\.id), ["watch-2"])
  }

  @MainActor func testReopeningKeepsMarks() throws {
    store.saveDeviceMarks([mark("watch-1", at: ten)], device: "phone-a", clockOffset: 0)
    store = try Store(directory: directory)
    XCTAssertEqual(store.deviceMarks(ids: ["watch-1"]).count, 1)
  }

  // MARK: The day page

  @MainActor func testDayShowsMarksInTheirHourButNotInPrivateTime() {
    store.saveDeviceMarks(
      // "eleven" starts exactly on the hour: it belongs to 11:00 only.
      [mark("ten", at: ten.addingTimeInterval(600)), mark("eleven", at: ten.addingTimeInterval(3_600), tag: "todo"),
       mark("twelve", at: ten.addingTimeInterval(7_200 + 60))],
      device: "phone-a", clockOffset: 0)
    store.addMark(.privateRange, start: ten.addingTimeInterval(7_200), end: ten.addingTimeInterval(10_800))

    let data = DayData.load(day: ten, store: store)

    let hour = { (start: Date) in data.hours.first { $0.interval.start == start } }
    XCTAssertEqual(hour(ten)?.deviceMarks.map(\.id), ["ten"])
    XCTAssertEqual(hour(ten.addingTimeInterval(3_600))?.deviceMarks.map(\.id), ["eleven"])
    XCTAssertEqual(hour(ten.addingTimeInterval(7_200))?.deviceMarks, [])
    XCTAssertEqual(hour(ten.addingTimeInterval(7_200))?.state, .privateHour)
    // A marked hour gets a row even with nothing recorded on the Mac.
    XCTAssertTrue(data.rows.contains { $0.interval.start == ten })
  }

  // MARK: End to end

  /// A Watch session with a tagged "记下刚才" travels as the phone sends it: over the paired TLS
  /// connection, into the library, onto the day page. With `WAKEONCUE_SEED_DIR` set (pass
  /// `TEST_RUNNER_WAKEONCUE_SEED_DIR` to xcodebuild) the library is left there, to open with
  /// `WAKEONCUE_DATA_DIR` and `WAKEONCUE_VIEW_ONLY`.
  @MainActor func testSimulatedWatchSessionReachesTheDayPage() async throws {
    let seed = ProcessInfo.processInfo.environment["WAKEONCUE_SEED_DIR"] ?? ""
    let library = seed.isEmpty ? store! : try Store(directory: URL(filePath: seed, directoryHint: .isDirectory))
    // Today, a little over an hour ago, so the page opens on it.
    let hour = Calendar.current.hourStart(.now.addingTimeInterval(-3_600))
    let watchStart = hour.addingTimeInterval(10 * 60)
    for (index, text) in ["我们把报价单改成按季度结算吧。", "好，那我周五前把新版本发给财务。", "另外下周记得约供应商对一下交期。"].enumerated() {
      let start = watchStart.addingTimeInterval(Double(index) * 40 + 75)
      library.insertSentence(start: start, end: start.addingTimeInterval(4), channel: .remote, speaker: .me, source: "Apple Watch", text: text)
    }
    let session = "8f0c2a7e-5b1d-4c3e-9a6f-2d7e1b4c9a10"
    // What MacOutbox.marks(of:) makes of a summary with "记下刚才" at 2:00 tagged 重要 and a
    // point mark at 4:00 tagged 待办.
    let marks = [
      SyncProtocol.MarkInfo(
        id: "watch-\(session)-a1", source: "watch", recordingID: session, start: watchStart.addingTimeInterval(0),
        end: watchStart.addingTimeInterval(120), tag: "important", title: nil),
      SyncProtocol.MarkInfo(
        id: "watch-\(session)-a2", source: "watch", recordingID: session, start: watchStart.addingTimeInterval(240),
        end: nil, tag: "todo", title: nil),
    ]

    let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let parameters = SyncProtocol.parameters(keys: [("phone-test", key)])
    let listener = try NWListener(using: parameters, on: .any)
    let queue = DispatchQueue(label: "DeviceMarkTests")
    let received = expectation(description: "Mac stored the marks")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      Task { @MainActor in
        let channel = SyncChannel(connection)
        guard case .marks(let marks) = try await channel.receive().0 else { return XCTFail("expected marks") }
        // As SyncServer does, with a known offset of 1.5 s for this phone.
        library.saveDeviceMarks(marks, device: "phone-test", clockOffset: 1.5)
        try await channel.send(.marksStored(ids: marks.map(\.id)))
        received.fulfill()
      }
    }
    let port = try await Self.ready(listener, queue: queue)
    defer { listener.cancel() }
    let client = NWConnection(host: "127.0.0.1", port: port, using: parameters)
    try await Self.ready(client, queue: queue)
    defer { client.cancel() }
    let channel = SyncChannel(client)
    try await channel.send(.marks(marks))
    guard case .marksStored(let ids) = try await channel.receive().0 else { return XCTFail("expected marksStored") }
    XCTAssertEqual(Set(ids), Set(marks.map(\.id)))
    await fulfillment(of: [received], timeout: 5)

    let data = DayData.load(day: hour, store: library)
    let row = try XCTUnwrap(data.rows.first { $0.interval.start == hour })
    XCTAssertEqual(row.deviceMarks.map(\.tag), [.important, .todo])
    XCTAssertEqual(row.deviceMarks.first?.start, watchStart.addingTimeInterval(1.5))
    XCTAssertEqual(row.deviceMarks.last?.end, nil)
  }

  /// A Mac that goes quiet mid-sync must not hold the phone's sync forever.
  func testSilentPeerTimesOut() async throws {
    let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let parameters = SyncProtocol.parameters(keys: [("phone-test", key)])
    let listener = try NWListener(using: parameters, on: .any)
    let queue = DispatchQueue(label: "DeviceMarkTests.silent")
    let accepted = Box()
    listener.newConnectionHandler = { connection in
      accepted.connection = connection  // Kept open, never answered.
      connection.start(queue: queue)
    }
    let port = try await Self.ready(listener, queue: queue)
    defer {
      listener.cancel()
      accepted.connection?.cancel()
    }
    let client = NWConnection(host: "127.0.0.1", port: port, using: parameters)
    try await Self.ready(client, queue: queue)
    let channel = SyncChannel(client, idleTimeout: 1)
    try await channel.send(.marks([]))
    let started = Date.now
    do {
      _ = try await channel.receive()
      XCTFail("expected a timeout")
    } catch SyncChannel.Failure.timedOut {
      XCTAssertLessThan(Date.now.timeIntervalSince(started), 5)
    }
  }

  private final class Box: @unchecked Sendable {
    var connection: NWConnection?
  }

  private static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> NWEndpoint.Port {
    try await withCheckedThrowingContinuation { continuation in
      let once = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { continuation.resume(returning: listener.port!) }
        case .failed(let error): if once.take() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  private static func ready(_ connection: NWConnection, queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { continuation.resume() }
        case .failed(let error), .waiting(let error): if once.take() { continuation.resume(throwing: error) }
        default: break
        }
      }
      connection.start(queue: queue)
    }
  }

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
  }

  private func segment(_ id: String, recording: String) -> SyncProtocol.SegmentInfo {
    SyncProtocol.SegmentInfo(
      id: id, source: "watch", recordingID: recording, index: 1, startedAt: ten, duration: 60, bytes: 1, sha256: "", format: "m4a")
  }
}
