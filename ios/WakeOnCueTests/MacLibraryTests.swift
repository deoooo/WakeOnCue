import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

@MainActor
final class MacLibraryTests: XCTestCase {
  private var root: URL!
  private var layout: RecordingFileLayout!
  private var store: RecordingStore!
  private var library: RecordingLibraryService!
  private let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appending(path: "mac-library-\(UUID())")
    layout = try RecordingFileLayout(root: root)
    store = try RecordingStore(databaseURL: layout.databaseURL)
    library = RecordingLibraryService(layout: layout, store: store, macOutboxRoot: root.appending(path: "outbox"))
    MacLibraryState.reset()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    MacLibraryState.reset()
  }

  private var dayKey: String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  private func conversation(_ id: String, at hour: Double, text: String, devices: [SyncProtocol.DeviceRecording] = []) -> SyncProtocol.LibraryConversation {
    let start = day.addingTimeInterval(hour * 3_600)
    return SyncProtocol.LibraryConversation(
      id: id, start: start, end: start.addingTimeInterval(120), sources: ["Mac"], title: nil, overview: nil,
      keyPoints: [], todos: [],
      sentences: [
        .init(id: 1, start: start, end: start.addingTimeInterval(5), speaker: "me", name: nil, text: text),
        .init(id: 2, start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), speaker: "other", name: "小林", text: "好的"),
      ],
      deviceRecordings: devices, digest: "\(id)-\(text)")
  }

  private var importer: MacLibraryImporter { MacLibraryImporter(store: store, layout: layout, library: library) }

  func testDayBecomesRecordingsWithTranscriptAndHidesTheIPhonesOwnCopy() async throws {
    // This iPhone recorded the same talk and sent it to the Mac.
    let own = RecordingRecord(
      id: "rec_own", createdAt: day.addingTimeInterval(9 * 3_600), startedAt: day.addingTimeInterval(9 * 3_600),
      status: .recording, localAudioPath: try layout.sourceAudioURL(recordingID: "rec_own").path,
      deviceModel: "test", appVersion: "test")
    try await store.createRecording(own, createPayloadPath: "", enqueueUpload: false)
    try await store.completeLocally(recordingID: "rec_own", duration: 60)

    let first = SyncProtocol.LibraryDay(day: dayKey, digest: "d1", conversations: [
      conversation("c1", at: 9, text: "早上好", devices: [.init(source: "iphone", recordingID: "rec_own")]),
      conversation("c9", at: 14, text: "下午"),
    ])
    let changed = try await importer.apply(first, language: .simplifiedChinese)
    XCTAssertEqual(Set(changed.map(\.id)), ["mac_c1", "mac_c9"])
    XCTAssertEqual(MacLibraryState.days[dayKey], "d1")

    let listed = try await library.recordings(startedIn: DateInterval(start: day, duration: 86_400))
    XCTAssertEqual(listed.map(\.id), ["mac_c9", "mac_c1"], "The iPhone's own copy is no longer listed")
    let transcript = try JSONDecoder().decode(
      [RealtimeTranscriptEvent].self, from: Data(contentsOf: layout.transcriptURL(recordingID: "mac_c1")))
    XCTAssertEqual(transcript.map(\.text), ["早上好", "好的"])
    XCTAssertEqual(transcript[1].startMilliseconds, 60_000)
    XCTAssertEqual(transcript[0].speaker?.personID, RealtimeSpeaker.selfPersonID)
    XCTAssertEqual(transcript[1].speaker?.displayName, "小林")

    // Unchanged digests change nothing; a changed one rewrites; a missing one is removed.
    let second = SyncProtocol.LibraryDay(day: dayKey, digest: "d2", conversations: [
      conversation("c1", at: 9, text: "早上好", devices: [.init(source: "iphone", recordingID: "rec_own")]),
    ])
    let again = try await importer.apply(second, language: .simplifiedChinese)
    XCTAssertTrue(again.isEmpty)
    let remaining = try await library.recordings(startedIn: DateInterval(start: day, duration: 86_400))
    XCTAssertEqual(remaining.map(\.id), ["mac_c1"])
    let gone = try await store.wasPermanentlyDeleted(recordingID: "mac_c9")
    XCTAssertTrue(gone)
  }

  func testDeletingOnTheIPhoneQueuesAnEditAndIsNotUndoneByTheNextDay() async throws {
    let day1 = SyncProtocol.LibraryDay(day: dayKey, digest: "d1", conversations: [conversation("c1", at: 9, text: "早")])
    _ = try await importer.apply(day1, language: .english)
    let recording = try await store.recording(id: "mac_c1")
    try await library.moveToTrash(recordingID: recording.id)
    MacLibraryState.enqueue(.delete, recording: recording)
    XCTAssertEqual(MacLibraryState.pendingEdits.map(\.kind), [.delete])
    XCTAssertEqual(MacLibraryState.pendingEdits.first?.conversationID, "c1")

    // The Mac has not applied the delete yet and sends the conversation again.
    let changed = try await importer.apply(
      SyncProtocol.LibraryDay(day: dayKey, digest: "d2", conversations: [conversation("c1", at: 9, text: "早，改")]),
      language: .english)
    XCTAssertTrue(changed.isEmpty)
    let stillDeleted = try await store.recording(id: "mac_c1").isDeleted
    XCTAssertTrue(stillDeleted)

    MacLibraryState.removeEdits(ids: MacLibraryState.pendingEdits.map(\.id))
    XCTAssertTrue(MacLibraryState.pendingEdits.isEmpty)
  }

  func testRenameReplacesOneNotYetSent() async throws {
    _ = try await importer.apply(
      SyncProtocol.LibraryDay(day: dayKey, digest: "d1", conversations: [conversation("c1", at: 9, text: "早")]),
      language: .english)
    let recording = try await store.recording(id: "mac_c1")
    MacLibraryState.enqueue(.rename, recording: recording, value: "一")
    MacLibraryState.enqueue(.rename, recording: recording, value: "二")
    XCTAssertEqual(MacLibraryState.pendingEdits.map(\.value), ["二"])
  }

  func testWatchRecordingsAreNamedTheWayThisIPhoneImportedThem() {
    let session = UUID()
    XCTAssertEqual(
      MacConversation.localRecordingID(.init(source: "watch", recordingID: session.uuidString)),
      WatchSessionSummary.recordingID(for: session))
    XCTAssertEqual(MacConversation.localRecordingID(.init(source: "iphone", recordingID: "rec_1")), "rec_1")
  }
}
