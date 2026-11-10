import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class ReviewDataTests: XCTestCase {
  /// A Watch recording is saved on the iPhone long after it started; it still belongs to the
  /// day it started, and paging past newer recordings must still find it.
  func testRecordingsStartedInADayFollowStartTimeAcrossPages() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "review-day-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try RecordingFileLayout(root: root)
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: Date()).addingTimeInterval(-3 * 86_400)
    let next = day.addingTimeInterval(86_400)

    func add(_ id: String, started: Date, saved: Date) async throws {
      let recording = RecordingRecord(
        id: id, createdAt: saved, startedAt: started, status: .recording,
        localAudioPath: try layout.sourceAudioURL(recordingID: id).path,
        deviceModel: "test", appVersion: "test")
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
      try await store.completeLocally(recordingID: id, duration: 60)
    }
    try await add("before", started: day.addingTimeInterval(-60), saved: day.addingTimeInterval(-30))
    try await add("morning", started: day.addingTimeInterval(9 * 3_600), saved: day.addingTimeInterval(9 * 3_600 + 60))
    try await add("evening", started: day.addingTimeInterval(20 * 3_600), saved: day.addingTimeInterval(20 * 3_600 + 60))
    // Recorded on the Watch that day, saved to the iPhone two days later.
    try await add("watch", started: day.addingTimeInterval(12 * 3_600), saved: next.addingTimeInterval(2 * 86_400))
    for index in 0..<5 {
      let later = next.addingTimeInterval(Double(index) * 600)
      try await add("later-\(index)", started: later, saved: later)
    }

    let service = try RecordingLibraryService(layout: layout)
    let found = try await service.recordings(
      startedIn: DateInterval(start: day, end: next), pageSize: 2)
    XCTAssertEqual(found.map(\.id), ["evening", "watch", "morning"])
  }

  func testDayRecapFingerprintChangesOnlyWithItsConversations() {
    let date = Date(timeIntervalSince1970: 1_000)
    let a = DayRecap.fingerprint([("a", date), ("b", date)])
    XCTAssertEqual(a, DayRecap.fingerprint([("b", date), ("a", date)]), "Order does not matter")
    XCTAssertNotEqual(a, DayRecap.fingerprint([("a", date)]))
    XCTAssertNotEqual(a, DayRecap.fingerprint([("a", date), ("b", date.addingTimeInterval(5))]))
  }

  @MainActor
  func testTodoCompletionIgnoresSurroundingWhitespace() {
    let defaults = UserDefaults(suiteName: "todo-\(UUID())")!
    let todos = TodoCompletion(defaults: defaults)
    XCTAssertFalse(todos.isDone(recordingID: "r", item: "Buy tickets"))
    todos.toggle(recordingID: "r", item: "Buy tickets ")
    XCTAssertTrue(todos.isDone(recordingID: "r", item: "Buy tickets"))
    XCTAssertFalse(todos.isDone(recordingID: "other", item: "Buy tickets"))
    todos.toggle(recordingID: "r", item: "Buy tickets")
    XCTAssertFalse(todos.isDone(recordingID: "r", item: "Buy tickets"))
  }
}
