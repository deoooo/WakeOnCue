import Foundation
import XCTest

@testable import WakeOnCue

/// The Watch and iPhone "记下刚才" marks on their way to the Mac (docs/sync-protocol.md).
final class MacOutboxMarksTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "MacOutboxMarksTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testWatchSummaryBookmarksBecomeMarksAtTheirRealTime() {
    let session = UUID()
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let bookmark = WatchSessionBookmark(position: 300, duration: 120, tag: .important)
    let point = WatchSessionBookmark(position: 30)
    let summary = WatchSessionSummary(
      sessionID: session, startedAt: started, endedAt: started.addingTimeInterval(600), segmentCount: 10,
      bookmarks: [bookmark, point])

    let marks = MacOutbox.marks(of: summary)

    XCTAssertEqual(marks.count, 2)
    let sessionID = session.uuidString.lowercased()
    // Same recording ID as the Watch segments, so the Mac can use their clock offset.
    XCTAssertEqual(marks[0].recordingID, sessionID)
    XCTAssertEqual(marks[0].id, "watch-\(sessionID)-\(bookmark.id.uuidString.lowercased())")
    XCTAssertEqual(marks[0].source, "watch")
    XCTAssertEqual(marks[0].start, started.addingTimeInterval(300))
    XCTAssertEqual(marks[0].end, started.addingTimeInterval(420))
    XCTAssertEqual(marks[0].tag, "important")
    XCTAssertNil(marks[1].end)
    XCTAssertNil(marks[1].tag)
  }

  func testIPhoneBookmarksBecomeMarks() {
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let bookmarks = [
      RecordingBookmark(position: 60, title: "  报价  ", duration: 120, tag: .todo),
      RecordingBookmark(position: 10, duration: 0),
    ]

    let marks = MacOutbox.marks(of: bookmarks, recordingID: "rec_1", startedAt: started)

    XCTAssertEqual(marks[0].id, "iphone-rec_1-\(bookmarks[0].id.uuidString.lowercased())")
    XCTAssertEqual(marks[0].source, "iphone")
    XCTAssertEqual(marks[0].recordingID, "rec_1")
    XCTAssertEqual(marks[0].start, started.addingTimeInterval(60))
    XCTAssertEqual(marks[0].end, started.addingTimeInterval(180))
    XCTAssertEqual(marks[0].tag, "todo")
    XCTAssertEqual(marks[0].title, "报价")
    XCTAssertNil(marks[1].end, "a zero-length span is a point mark")
  }

  func testMarksWaitUntilTheMacConfirmsThem() throws {
    let now = Date()
    let first = mark("watch-a-1", at: now.addingTimeInterval(-600))
    let second = mark("watch-a-2", at: now.addingTimeInterval(-300))
    try MacOutbox.enqueue(marks: [second, first], root: root)

    XCTAssertEqual(MacOutbox.marks(root: root, now: now).map(\.id), ["watch-a-1", "watch-a-2"], "oldest first")

    // Queuing the same ID again replaces it, e.g. after its tag changed.
    var tagged = first
    tagged.tag = "todo"
    try MacOutbox.enqueue(marks: [tagged], root: root)
    XCTAssertEqual(MacOutbox.marks(root: root, now: now).count, 2)
    XCTAssertEqual(MacOutbox.marks(root: root, now: now).first?.tag, "todo")

    MacOutbox.removeMarks(ids: ["watch-a-1"], root: root)
    XCTAssertEqual(MacOutbox.marks(root: root, now: now).map(\.id), ["watch-a-2"])
  }

  func testMarksInTimeTheMacDroppedAreForgotten() throws {
    let now = Date()
    let inside = mark("watch-a-1", at: now.addingTimeInterval(-3_000))
    let outside = mark("watch-a-2", at: now.addingTimeInterval(-600))
    try MacOutbox.enqueue(marks: [inside, outside], root: root)

    MacOutbox.dropMarks(
      in: [SyncProtocol.Range(kind: "private", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800))],
      root: root)

    XCTAssertEqual(MacOutbox.marks(root: root, now: now).map(\.id), ["watch-a-2"])
  }

  func testMarksAnOlderMacNeverTookAreGivenUpEventually() throws {
    let now = Date()
    try MacOutbox.enqueue(marks: [mark("old", at: now.addingTimeInterval(-MacOutbox.markLifetime - 1))], root: root)
    XCTAssertTrue(MacOutbox.marks(root: root, now: now).isEmpty)
  }

  func testOddIDsStillMakeOneFile() throws {
    try MacOutbox.enqueue(marks: [mark("iphone-rec/../1", at: .now)], root: root)
    XCTAssertEqual(MacOutbox.marks(root: root).map(\.id), ["iphone-rec/../1"])
    MacOutbox.removeMarks(ids: ["iphone-rec/../1"], root: root)
    XCTAssertTrue(MacOutbox.marks(root: root).isEmpty)
  }

  // MARK: Protocol

  func testOlderMacWelcomeWithoutFeaturesStillDecodes() throws {
    // What a Mac from before marks sends.
    let json = #"{"welcome":{"macName":"Mac","accepting":true,"drop":[]}}"#
    let message = try SyncProtocol.decodeHeader(Data(json.utf8))
    guard case .welcome(_, let accepting, _, let features) = message else { return XCTFail("\(message)") }
    XCTAssertTrue(accepting)
    XCTAssertNil(features, "no features: the phone must not send marks")
  }

  func testMarksRoundTrip() throws {
    let message = SyncProtocol.Message.marks([mark("watch-a-1", at: Date(timeIntervalSince1970: 1_800_000_000))])
    let frame = try SyncProtocol.frame(message)
    let length = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    XCTAssertEqual(try SyncProtocol.decodeHeader(frame.dropFirst(4).prefix(length)), message)
  }

  private func mark(_ id: String, at start: Date) -> SyncProtocol.MarkInfo {
    SyncProtocol.MarkInfo(
      id: id, source: "watch", recordingID: "a", start: start, end: start.addingTimeInterval(120), tag: "important", title: nil)
  }
}
